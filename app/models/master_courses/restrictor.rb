# frozen_string_literal: true

#
# Copyright (C) 2016 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.

module MasterCourses::Restrictor
  # a helper module included in various course content classes to streamline the integration for locking
  # and preventing changes made downstream (to copies in the associated course) from being overwritten

  # *** example usage: ***
  #   include MasterCourses::Restrictor
  #   restrict_columns :content, [:body, :title]

  # will mean that the :body and :title columns of the object are part of the :content restriction class
  # if :content is locked by the corresponding blueprint's MasterContentTag, then changes to either column
  # will automatically throw errors

  # columns can be added to restriction classes that are not exposed to the UI (e.g. :settings)
  # and thus can never actually be locked
  # adding the restrictor can still be useful because it will also keep track of changes to the columns
  # and add any changed column to the :downstream_changes attribute of the corresponding ChildContentTag
  # so if a future blueprint sync comes along and tries to overwrite the changed columns
  # it will auto-magically ignore them (make sure to call `mark_as_importing!` in the importer)

  def self.included(klass)
    klass.include(CommonMethods)
    klass.send(:attr_writer, :child_content_restrictions)
    klass.send(:attr_accessor, :current_master_template_restrictions)

    klass.after_create :create_child_content_tag

    klass.after_update :mark_downstream_changes

    # luckily before_update comes after before_save in case we do sneaky changes in models
    klass.before_update :check_before_overwriting_child_content_on_import
  end

  module CommonMethods # i didn't want to copypaste all this into the collection one
    def self.included(klass)
      klass.cattr_accessor :restricted_column_settings
      klass.restricted_column_settings = {}

      klass.extend ClassMethods
      klass.validate :check_for_restricted_column_changes
    end

    module ClassMethods
      def restrict_columns(edit_type, columns)
        raise "invalid restriction type" unless MasterCourses::LOCK_TYPES.include?(edit_type)

        columns = Array(columns).map(&:to_s)
        current = restricted_column_settings[edit_type] || []
        restricted_column_settings[edit_type] = (current + columns).uniq
      end

      def restrict_assignment_columns
        restrict_columns :settings, %i[assignment_group_id
                                       grading_type
                                       omit_from_final_grade
                                       submission_types
                                       group_category
                                       group_category_id
                                       grade_group_students_individually
                                       peer_reviews
                                       moderated_grading
                                       peer_reviews_due_at
                                       allowed_attempts]
        restrict_columns :due_dates, [:due_at]
        restrict_columns :availability_dates, [:lock_at, :unlock_at]
        restrict_columns :points, [:points_possible]
      end
    end

    def mark_as_importing!(cm)
      @importing_migration = cm if cm&.master_course_subscription
      # if we are doing a course copy and the source course has up-to-date search embeddings,
      # we will copy those embeddings in batches instead of regenerating them
      self.skip_embeddings = true if cm&.for_course_copy? && respond_to?(:skip_embeddings=) &&
                                     SmartSearch.up_to_date?(cm.source_course)
    end

    def skip_downstream_changes!
      @skip_downstream_changes = true
    end

    def downstream_changes?(migration, column)
      migration.for_master_course_import? &&
        migration.master_course_subscription.content_tag_for(self)&.downstream_changes&.include?(column)
    end

    def check_for_restricted_column_changes
      return true if !check_restrictions? || skip_restrictions?

      return true if is_a?(Lti::LineItem) && !Account.site_admin.feature_enabled?(:blueprint_line_item_support) # hopefully remove when the FF is retired

      locked_columns = []
      self.class.base_class.restricted_column_settings.each do |type, columns|
        changed_columns = (changes.keys & columns)
        if changed_columns.any? && child_content_restrictions[type]
          locked_columns += changed_columns
        end
      end
      if locked_columns.any?
        errors.add(:base, "cannot change column(s): #{locked_columns.join(", ")} - locked by Master Course")
      end
    end

    def editing_restricted?(edit_type = :all) # edit_type can be :all, :any, or a specific type: :content, :settings, :due_dates, :availability_dates, :points
      return false unless is_child_content?

      restrictions = child_content_restrictions
      return false unless restrictions.present?
      return true if restrictions[:all]

      case edit_type
      when :all
        self.class.base_class.restricted_column_settings.keys.all? { |type| restrictions[type] } # make it possible to only have restrictions on one type
      when :any
        self.class.base_class.restricted_column_settings.keys.any? { |type| restrictions[type] }
      when *MasterCourses::LOCK_TYPES
        !!restrictions[edit_type]
      else
        raise "invalid edit type"
      end
    end

    def skip_restrictions?
      @importing_migration || @skip_downstream_changes || !is_child_content? # don't mark changes on import
    end
  end

  def check_restrictions?
    !new_record?
  end

  def mark_downstream_changes(changed_columns = nil)
    return if skip_restrictions?

    changed_columns ||= saved_changes.keys & self.class.base_class.restricted_column_settings.values.flatten
    state_column = is_a?(Attachment) ? "file_state" : "workflow_state"
    if saved_changes[state_column]&.last == "deleted"
      changed_columns.delete(state_column)
      changed_columns << "manually_deleted"
    end
    if changed_columns.any?
      tag_content = if is_a?(Assignment) && (submittable = submittable_object)
                      submittable # mark on the owner's tag
                    else
                      self
                    end
      MasterCourses::ChildContentTag.transaction do
        child_tag = MasterCourses::ChildContentTag.where(content: tag_content).lock.first
        if child_tag
          new_changes = changed_columns - child_tag.downstream_changes
          if new_changes.any?
            child_tag.downstream_changes += new_changes
            child_tag.save!
          end
        else
          Rails.logger.warn("Child content tag was not found for #{self.class.name} #{id} - either this is from old code or something bad happened")
        end
      end
    end
  end

  def create_child_content_tag
    # i thought about making this a bulk insert at the end of the migration but the race conditions seemed scary
    if @importing_migration && is_child_content?
      @importing_migration.master_course_subscription.content_tag_for(self)
    end
  end

  def check_before_overwriting_child_content_on_import
    return unless @importing_migration && is_child_content?

    child_tag = @importing_migration.master_course_subscription.content_tag_for(self) # find or create it
    return unless child_tag && child_tag.downstream_changes.present?

    columns_to_restore = []
    self.class.base_class.restricted_column_settings.each do |type, columns|
      changed_columns = (child_tag.downstream_changes & columns) # should unlink all changes if _any_ in the category has been changed
      if changed_columns.any?
        if child_content_restrictions[type] # don't overwrite downstream changes _unless_ it's locked
          child_tag.downstream_changes -= changed_columns # remove them from the downstream changes since we overwrote
          child_tag.save!
        else
          # if not locked then we should undo _all_ the changes in the category (content or settings) we were about to make
          columns_to_restore += (changes.keys & columns)
        end
      end
    end

    state_column = is_a?(Attachment) ? "file_state" : "workflow_state"
    if changes[state_column]&.first == "deleted" && child_tag.downstream_changes.include?("manually_deleted")
      if editing_restricted?(:any)
        child_tag.downstream_changes.delete("manually_deleted")
        child_tag.save!
      else
        columns_to_restore << state_column # don't restore if we manually deleted it
      end
    end

    if columns_to_restore.any?
      @importing_migration.add_skipped_item(child_tag)
      Rails.logger.debug("Undoing imported changes to #{self.class} #{id} because changed downstream - #{columns_to_restore.join(", ")}")
      restore_attributes(columns_to_restore)
    end
  end

  def edit_types_locked_for_overwrite_on_import
    return [] unless @importing_migration && is_child_content?

    # this is just a read-only method to check whether we _can_ overwrite
    # should help on import when checking on collection items that aren't instantiated
    # e.g. assessment questions in a bank

    child_tag = @importing_migration.master_course_subscription.content_tag_for(self)
    return [] unless child_tag.downstream_changes.present?

    locked_types = []
    self.class.base_class.restricted_column_settings.each do |type, columns|
      if !child_content_restrictions[type] && child_tag.downstream_changes.intersect?(columns)
        locked_types << type
      end
    end

    locked_types
  end

  def is_child_content?
    migration_id&.start_with?(MasterCourses::MIGRATION_ID_PREFIX)
  end

  def child_content_restrictions
    @child_content_restrictions ||= find_child_content_restrictions || {}
  end

  def master_course_api_restriction_data(course_status)
    hash = {}
    if course_status == :child && is_child_content?
      hash["is_master_course_child_content"] = true
      is_restricted = editing_restricted?(:any)
      hash["restricted_by_master_course"] = is_restricted
      hash["master_course_restrictions"] = child_content_restrictions if is_restricted
    elsif course_status == :master && current_master_template_restrictions
      hash["is_master_course_master_content"] = true
      is_restricted = current_master_template_restrictions.values.any? { |v| v }
      hash["restricted_by_master_course"] = is_restricted
      hash["master_course_restrictions"] = current_master_template_restrictions if is_restricted
    end
    hash
  end

  def find_child_content_restrictions
    if @importing_migration
      @importing_migration.master_course_subscription.master_template.find_preloaded_restriction(migration_id) # for extra speeds on import
    else
      MasterCourses::MasterContentTag.where(migration_id:).pick(:restrictions)
    end
  end

  def child_content_restrictions_loaded?
    !!@child_content_restrictions
  end

  # preload restrictions on the child course
  def self.preload_child_restrictions(objects)
    objects = Array(objects)
    objects_to_load = objects.select do |obj|
      !obj.is_a?(Folder) && obj.is_child_content? && !obj.child_content_restrictions_loaded?
    end.index_by(&:migration_id)
    migration_ids = objects_to_load.keys
    return unless migration_ids.any?

    objects_to_load.each_value { |obj| obj.child_content_restrictions = {} } # default if restrictions are missing
    all_restrictions = MasterCourses::MasterContentTag.where(migration_id: migration_ids).pluck(:migration_id, :restrictions)
    all_restrictions.each do |migration_id, restrictions|
      objects_to_load[migration_id].child_content_restrictions = restrictions
    end
  end

  def self.preload_default_template_restrictions(objects, course)
    # this is for preloading restrictions on the master/blueprint course side
    # this is basically almost the same as the child side and it really isn't obvious what the difference is
    # this all is probably going to be confusing to the poor soul that reads this
    template = MasterCourses::MasterTemplate.full_template_for(course)
    return unless template

    objects_to_load = Array(objects).select { |obj| MasterCourses::ALLOWED_CONTENT_TYPES.include?(obj.class.base_class.name) }.index_by do |obj|
      template.migration_id_for(obj) # use their future migration ids because that'll actually make partial bulk-loading easier
    end

    objects_to_load.each_value { |obj| obj.current_master_template_restrictions = {} } # default if restrictions are missing
    template.master_content_tags.where(migration_id: objects_to_load.keys).pluck(:migration_id, :restrictions).each do |migration_id, restrictions|
      objects_to_load[migration_id].current_master_template_restrictions = restrictions
    end
  end
end
