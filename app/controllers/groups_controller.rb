require 'fastercsv'
require 'auto_complete'

# Manages actions relating to editing and modifying 
# groups.
class GroupsController < ApplicationController
  include GroupsHelper
  # Administrator
  # -
  before_filter      :authorize_only_for_admin
   
  auto_complete_for :student, :user_name
  auto_complete_for :assignment, :name
  
  def note_message
    @assignment = Assignment.find(params[:id])
    if params[:success]
      flash[:upload_notice] = I18n.t('notes.create.success')
    else
      flash[:error] = I18n.t('notes.error')
    end
  end
 
  # Group administration functions -----------------------------------------
  # Verify that all functions below are included in the authorize filter above
    
  def add_member    
    return unless (request.post? && params[:student_user_name])
    # add member to the group with status depending if group is empty or not
    grouping = Grouping.find(params[:grouping_id])
    @assignment = Assignment.find(params[:id], :include => [{:groupings => [{:student_memberships => :user, :ta_memberships => :user}, :group]}])
    set_membership_status = grouping.student_memberships.empty? ?
          StudentMembership::STATUSES[:inviter] :
          StudentMembership::STATUSES[:accepted]
    @messages = []
    @bad_user_names = []
    @error = false
    
    students = params[:student_user_name].split(',')

    students.each do |user_name|
      user_name = user_name.strip
      @invited = Student.find_by_user_name(user_name)
      begin
        if @invited.nil?
          raise I18n.t('add_student.fail.dne', :user_name => user_name)
        end
        if @invited.hidden
          raise I18n.t('add_student.fail.hidden', :user_name => user_name)
        end
        if @invited.has_accepted_grouping_for?(@assignment.id)
          raise I18n.t('add_student.fail.already_grouped', :user_name => user_name)
        end
        grouping.invite(user_name, set_membership_status)

        @messages.push(I18n.t('add_student.success', :user_name => user_name))
        
        # only the first student should be the "inviter" (and only update this if it succeeded)
        set_membership_status = StudentMembership::STATUSES[:accepted]
      rescue Exception => e
        @error = true
        @messages.push(e.message)
        @bad_user_names.push(user_name)
      end
    end

    grouping.reload
    @grouping = construct_table_row(grouping, @assignment)
    @group_name = grouping.group.group_name
  end
  
  def add_member_dialog
    @assignment = Assignment.find(params[:id])
    @grouping_id = params[:grouping_id]
    render :partial => "groups/modal_dialogs/add_member_dialog.rjs"
  end
 
  def remove_member
    return unless request.delete?
    
    @mbr_id = params[:mbr_id]
    @assignment = Assignment.find(params[:id])
    @grouping = Grouping.find(params[:grouping_id])
    member = @grouping.student_memberships.find(@mbr_id)  # use group as scope
    if member.membership_status == StudentMembership::STATUSES[:inviter]
        @inviter = true
    end
    
    @grouping.remove_member(member)
    if @inviter
      @inviter = @grouping.student_memberships.find_by_membership_status(StudentMembership::STATUSES[:inviter])
    else 
      @inviter = false
    end
  end
  
  def add_group
    @assignment = Assignment.find(params[:id])
    begin
      new_grouping_data = @assignment.add_group(params[:new_group_name])
    rescue Exception => e
      @error = e.message
      render :action => 'error_single'
      return 
    end
    @new_grouping = construct_table_row(new_grouping_data, @assignment)
  end
  
  def remove_group
    return unless request.delete?
    grouping = Grouping.find(params[:grouping_id])
    @assignment = grouping.assignment
    @errors = []
    @removed_groupings = []
    if grouping.has_submission?
        @errors.push(grouping.group.group_name)
        render :action => "delete_groupings"
    else
      grouping.delete_grouping
      @removed_groupings.push(grouping)
      render :action => "delete_groupings"
    end
  end
  
  def rename_group_dialog
    @assignment = Assignment.find(params[:id])
    @grouping_id = params[:grouping_id]
    render :partial => "groups/modal_dialogs/rename_group_dialog.rjs"
  end

  def rename_group
     @assignment = Assignment.find(params[:id])
     @grouping = Grouping.find(params[:grouping_id]) 
     @group = @grouping.group
    
     # Checking if a group with this name already exists

    if (@groups = Group.find(:first, :conditions => {:group_name =>
     [params[:new_groupname]]}))
         existing = true
         groupexist_id = @groups.id
    end
    
    if !existing
        #We update the group_name
        @group.group_name = params[:new_groupname]
        @group.save
        flash[:edit_notice] = I18n.t('groups.rename_group.success')
     else

        # We link the grouping to the group already existing

        # We verify there is no other grouping linked to this group on the
        # same assignement
        params[:groupexist_id] = groupexist_id
        params[:assignment_id] = @assignment.id

        if Grouping.find(:all, :conditions => ["assignment_id =
        :assignment_id and group_id = :groupexist_id", {:groupexist_id =>
        groupexist_id, :assignment_id => @assignment.id}])
           flash[:fail_notice] = I18n.t('groups.rename_group.already_in_use')
        else
          @grouping.update_attribute(:group_id, groupexist_id)
          flash[:edit_notice] = I18n.t('groups.rename_group.success')
        end
     end
  end

  def valid_grouping
     @assignment = Assignment.find(params[:id])
     grouping = Grouping.find(params[:grouping_id])
     grouping.validate_grouping
  end
  
  def populate
    @assignment = Assignment.find(params[:id], :include => [{:groupings => [{:student_memberships => :user, :ta_memberships => :user}, :group]}])   
    @groupings = @assignment.groupings
    @table_rows = {}
    @groupings.each do |grouping|
      # construct_table_row is in the groups_helper.rb
      @table_rows[grouping.id] = construct_table_row(grouping, @assignment) 
    end
    
  end

  def manage
    @all_assignments = Assignment.all(:order => :id)
    @assignment = Assignment.find(params[:id], :include => [{:groupings => [{:student_memberships => :user, :ta_memberships => :user}, :group]}])   
    @groupings = @assignment.groupings
    # Returns a hash where s.id is the key, and student record is the value
    @ungrouped_students = @assignment.ungrouped_students
    @tas = Ta.all
  end
  
  # Assign TAs to Groupings via a csv file
  def csv_upload_grader_mapping
    if !request.post? || params[:grader_mapping].nil?
      flash[:error] = "You must supply a CSV file for group to grader mapping"
      redirect_to :action => 'manage', :id => params[:id]
      return
    end
    
    invalid_lines = Grouping.assign_tas_by_csv(params[:grader_mapping].read, params[:id])
    if invalid_lines.size > 0
      flash[:invalid_lines] = invalid_lines
    end
    redirect_to :action => 'manage', :id => params[:id]
  end
  
  # Allows the user to upload a csv file listing groups.
  def csv_upload
    flash[:error] = nil # reset from previous errors
    flash[:invalid_lines] = nil
    @assignment = Assignment.find(params[:id])
    if request.post? && !params[:group].blank?
      # make this transactional
      ActiveRecord::Base.transaction do
        # if there exist groupings, delete them
        if !@assignment.groupings.nil? && @assignment.groupings.length > 0
          @assignment.groupings.destroy_all
        end
        num_update = 0
        flash[:invalid_lines] = []  # store lines that were not processed
        
        begin # start unsave code
          # Loop over each row, which lists the members to be added to the group.
          line_nr = 1
          flash[:users_not_found] = [] # contains a list of user_name(s) not found in DB
          FasterCSV.parse(params[:group][:grouplist]) do |row|
            retval = @assignment.add_csv_group(row)
            if retval == nil || retval.instance_of?(Array)
              if !retval.nil?
                flash[:invalid_lines] << "Line #{line_nr}: User(s) not found: " +retval.join(", ")
              else
                flash[:invalid_lines] << line_nr
              end
            else
              num_update += 1
            end
            line_nr += 1
          end
          msg = "#{num_update} group(s) added."
          msg += flash[:invalid_lines].length "lines contained errors." if flash[:invalid_lines].length > 0
          flash[:upload_notice] = msg
          flash[:invalid_lines] = nil if flash[:invalid_lines].length == 0
        rescue Exception
          flash[:error] = "There was an error regarding CSV upload."
          raise ActiveRecord::Rollback
        end
      end
    end
    redirect_to :action => "manage", :id => params[:id]
  end
  
  def download_grouplist
    assignment = Assignment.find(params[:id])

    #get all the groups
    groupings = assignment.groupings #FIXME: optimize with eager loading

    file_out = FasterCSV.generate do |csv|
       groupings.each do |grouping|
         group_array = [grouping.group.group_name, grouping.group.repo_name]
         # csv format is group_name, repo_name, user1_name, user2_name, ... etc
         grouping.student_memberships.all(:include => :user).each do |member|
            group_array.push(member.user.user_name);
         end
         csv << group_array
       end
     end

    send_data(file_out, :type => "text/csv", :disposition => "inline")
  end

  def use_another_assignment_groups
    @target_assignment = Assignment.find(params[:id])
    source_assignment = Assignment.find(params[:clone_groups_assignment_id])
      
    if source_assignment.nil?
      flash[:fail_notice] = "Could not find source assignment for cloning groups"
    end
    if @target_assignment.nil?
      flash[:fail_notice] = "Could not find target assignment for cloning groups"
    end
      
    # First, destroy all groupings for the target assignment
    @target_assignment.groupings.each do |grouping|
      grouping.destroy
    end
      
    # Next, we need to set the target assignments grouping settings to match
    # the source assignment

    @target_assignment.group_min = source_assignment.group_min
    @target_assignment.group_max = source_assignment.group_max
    @target_assignment.student_form_groups = source_assignment.student_form_groups
    @target_assignment.group_name_autogenerated = source_assignment.group_name_autogenerated
    @target_assignment.group_name_displayed = source_assignment.group_name_displayed
    
    source_groupings = source_assignment.groupings

    source_groupings.each do |old_grouping|
      #create the groupings
      new_grouping = Grouping.new
      new_grouping.assignment_id = @target_assignment.id
      new_grouping.group_id = old_grouping.group_id
      new_grouping.save
      #create the memberships - both TA and Student memberships
      old_memberships = old_grouping.memberships
      old_memberships.each do |old_membership|
        new_membership = Membership.new
        new_membership.user_id = old_membership.user_id
        new_membership.membership_status = old_membership.membership_status
        new_membership.grouping = new_grouping
        new_membership.type = old_membership.type
        new_membership.save
      end
    end

    flash[:edit_notice] = "Groups created"
  end

  # This method is massive, and does way too much.  Whatever happened
  # to single-responsibility?
  def global_actions 
    @assignment = Assignment.find(params[:id], :include => [{:groupings => [{:student_memberships => :user, :ta_memberships => :user}, :group]}])   
    @tas = Ta.all

    if params[:submit_type] == 'random_assign'
      begin 
        if params[:graders].nil?
          raise "You must select at least one grader for random assignment"
        end
        randomly_assign_graders(params[:graders], @assignment.groupings)
        @groupings_data = construct_table_rows(@assignment.groupings, @assignment)
        render :action => "modify_groupings"
        return
      rescue Exception => e
        @error = e.message
        render :action => 'error_single'
        return
      end
    end
    
    grouping_ids = params[:groupings]
    if params[:groupings].nil? or params[:groupings].size ==  0
      @error = "You need to select at least one group."
      render :action => 'error_single'
      return
    end
    @grouping_data = {}
    @groupings = []
    
    case params[:global_actions]
      when "delete"
        @removed_groupings = []
        @errors = []
        groupings = Grouping.find(grouping_ids)
        groupings.each do |grouping|
          if grouping.has_submission?
            @errors.push(grouping.group.group_name)
	        else
            grouping.delete_grouping
            @removed_groupings.push(grouping)
	        end
        end
        render :action => "delete_groupings"
        return
      
      when "invalid"
        groupings = Grouping.find(grouping_ids)
        groupings.each do |grouping|
           grouping.invalidate_grouping
        end
        @groupings_data = construct_table_rows(groupings, @assignment)
        render :action => "modify_groupings"
        return      
      
      when "valid"
        groupings = Grouping.find(grouping_ids)
        groupings.each do |grouping|
           grouping.validate_grouping
        end
        @groupings_data = construct_table_rows(groupings, @assignment)
        render :action => "modify_groupings"
        return
        
      when "assign"
        @groupings_data = assign_tas_to_groupings(grouping_ids, params[:graders])
        render :action => "modify_groupings"
        return
        
      when "unassign"
        @groupings_data = unassign_tas_to_groupings(grouping_ids, params[:graders])
        render :action => "modify_groupings"
        return
    end
  end


end
