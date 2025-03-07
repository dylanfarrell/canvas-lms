# frozen_string_literal: true

#
# Copyright (C) 2011 - present Instructure, Inc.
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
#

# This is used to take a zipped file, unzip it, add directories to a
# context, and attach the files in the correct directories.
class UnzipAttachment
  THINGS_TO_IGNORE_REGEX = /^(__MACOSX|thumbs\.db|\.DS_Store)$/

  def self.process(opts = {})
    @ua = new(opts)
    @ua.process
    @ua
  end

  attr_reader :context, :filename, :root_folders, :context_files_folder
  attr_accessor :progress_proc

  # for backwards compatibility
  def course
    context
  end

  def course_files_folder
    context_files_folder
  end

  def initialize(opts = {})
    @context = opts[:course] || opts[:context]
    @filename = opts[:filename]
    # opts[:callback] is for backwards-compatibility, it's just a progress proc
    # that doesn't expect any argument giving it the percent progress
    @progress_proc = opts[:callback]
    @context_files_folder = opts[:root_directory] || Folder.root_folders(@context).first
    @valid_paths = opts[:valid_paths]
    @logger ||= opts[:logger]
    @rename_files = !!opts[:rename_files]
    @migration_id_map = opts[:migration_id_map] || {}

    raise ArgumentError, "Must provide a context." unless context&.is_a_context?
    raise ArgumentError, "Must provide a filename." unless filename
    raise ArgumentError, "Must provide a context files folder." unless context_files_folder
  end

  def update_progress(pct)
    return unless @progress_proc

    if @progress_proc.arity == 0
      # for backwards compatibility with callback procs that expect no arguments
      @progress_proc.call
    else
      @progress_proc.call(pct)
    end
  end

  def logger
    @logger ||= Rails.logger
  end

  # For all files in a zip file,
  # 1) create a folder in the context like the one in the zip file, if necessary
  # 2) create a unique filename to store the file
  # 3) extract the file into the unique filename
  # 4) attach the file to the context, in the appropriate folder, with a decent display name
  #
  # E.g.,
  # the zipfile has some_entry/some_file.txt
  # the context will have root_folder/some_entry added to its folder structure
  # the filesystem will get an empty file called something like:
  # /tmp/some_file.txt20091012-16997-383kbv-0
  # the contents of some_entry/some_file.txt in the zip file will be extracted to
  # /tmp/some_file.txt20091012-16997-383kbv-0
  # The context will get the contents of this file added to a new attachment called 'Some file.txt'
  # added to the root_folder/some_entry folder in the database
  # Tempfile will unlink its new file as soon as f is garbage collected.
  def process
    Folder.reset_path_lookups!
    with_unzip_configuration do
      zip_stats.validate_against(context)

      id_positions = {}
      path_positions = zip_stats.paths_with_positions(last_position)
      not_created_folders = []
      CanvasUnzip.extract_archive(filename) do |entry, index|
        next if should_skip?(entry)

        folder_path_array = path_elements_for(@context_files_folder.full_name)
        entry_path_array = path_elements_for(entry.name)
        entry_path_array.pop

        folder_path_array += entry_path_array
        folder_name = folder_path_array.join("/")
        display_name = display_name(entry.name)
        if not_created_folders.include?(folder_name)
          @logger&.warn "Couldn't create file #{display_name}: #{folder_name} not created"
          next
        end
        begin
          folder = Folder.assert_path(folder_name, @context)
        rescue ActiveRecord::StatementInvalid => e
          @logger&.warn "Couldn't create sub-folder #{folder_name}: #{e.message}"
          not_created_folders << folder_name
          next
        end

        update_progress(zip_stats.percent_complete(index))

        # Hyphenate the path.  So, /some/file/path becomes some-file-path
        # Since Tempfile guarantees that the names are unique, we don't
        # have to worry about what this name actually is.
        Tempfile.open do |f|
          file_size = 0
          sha512 = entry.extract(f.path, true) do |bytes|
            file_size += bytes
          end
          zip_stats.charge_quota(file_size)
          # This is where the attachment actually happens.  See file_in_context.rb
          migration_id = @migration_id_map[entry.name]
          attachment = attach(f.path, entry, folder, sha512, migration_id:)
          id_positions[attachment.id] = path_positions[entry.name]
        rescue Attachment::OverQuotaError
          f.unlink
          raise
        rescue ActiveRecord::StatementInvalid => e
          @logger&.warn "Couldn't create file #{display_name}: #{e.message}"
        rescue => e
          @logger&.warn "Couldn't unzip archived file #{display_name}: #{e.message}"
        end
      end
      update_attachment_positions(id_positions)
    end

    @context.touch
    update_progress(1.0)
  end

  def zip_stats
    @zip_stats ||= ZipFileStats.new(filename)
  end

  def update_attachment_positions(id_positions)
    updates = id_positions.inject([]) do |memo, (id, position)|
      memo.tap { |m| m << "WHEN id=#{id} THEN #{position}" if id && position }
    end

    if updates.any?
      Attachment.where(id: id_positions.keys).update_all("position=CASE #{updates.join(" ")} ELSE position END")
    end
  end

  def attach(path, entry, folder, md5, migration_id: nil)
    FileInContext.attach(context,
                         path,
                         display_name: display_name(entry.name),
                         folder:,
                         explicit_filename: File.split(entry.name).last,
                         allow_rename: @rename_files,
                         md5:,
                         migration_id:)
  rescue
    FileInContext.attach(context,
                         path,
                         display_name: display_name(entry.name),
                         folder:,
                         explicit_filename: File.split(entry.name).last,
                         allow_rename: @rename_files,
                         md5:,
                         migration_id:)
  end

  def with_unzip_configuration
    Attachment.skip_touch_context do
      Attachment.skip_3rd_party_submits(true)
      FileInContext.queue_files_to_delete(true)
      yield
    ensure
      Attachment.skip_3rd_party_submits(false)
      FileInContext.queue_files_to_delete(false)
      FileInContext.destroy_queued_files
    end
  end

  def last_position
    @last_position ||= @context.attachments.active.filter_map(&:position).last || 0
  end

  def should_skip?(entry)
    entry.directory? ||
      entry.name.split("/").any? { |p| p =~ THINGS_TO_IGNORE_REGEX } ||
      (@valid_paths && !@valid_paths.include?(entry.name))
  end

  def path_elements_for(path)
    return [] unless path

    list = File.split(path)
    list.shift if list[0] == "."
    list
  end

  protected

  # Creates a title-ized name from a path.
  # So, display_name(/tmp/foo/bar_baz) generates 'Bar baz'
  def display_name(path)
    File.split(path).last
  end

  # Finds the folder in the database, creating the path if necessary
  def infer_folder(path)
    list = path.split("/")
    current = (@root_directory ||= folders.root_directory)
    # For every directory in the path...
    # (-2 means all entries but the last, which should be a filename)
    list[0..-2].each do |dir|
      current = if (new_dir = current.sub_folders.where(name: dir).first)
                  new_dir
                else
                  assert_folder(current, dir)
                end
    end
    current
  end

  # Actually creates the folder in the database.
  def assert_folder(root, dir)
    folder = Folder.new(parent_folder_id: root.id, name: dir)
    folder.context = context
    folder.save!
    folder
  end

  # A cached list of folders that we know about.
  # Used by infer_folder to know whether to create a folder or not.
  def folders(reset = false)
    @folders = nil if reset
    return @folders if @folders

    @folders = OpenStruct.new(root_directory: context_files_folder)
  end
end

# this is just a helper class that wraps an archive
# for just the duration of this operation; it doesn't
# quite seem appropriate to move it to it's own file
# since it's such an integral part of the unzipping
# process
class ZipFileStats
  MAX_FILE_COUNT = 250_000
  attr_reader :file_count, :total_size, :paths, :filename, :quota_remaining

  def initialize(filename)
    @filename = filename
    @paths = []
    @file_count = 0
    @total_size = 0
    @quota_remaining = nil
    process!
  end

  def validate_against(context)
    if file_count > MAX_FILE_COUNT
      raise ArgumentError, "Zip File cannot have more than #{MAX_FILE_COUNT} entries"
    end

    # check whether the nominal size of the zip's contents would exceed
    # quota, and reject the zip immediately if so
    quota_hash = Attachment.get_quota(context)
    if quota_hash[:quota] > 0
      if (quota_hash[:quota_used] + total_size) > quota_hash[:quota]
        raise Attachment::OverQuotaError, "Zip file would exceed quota limit"
      end

      @quota_remaining = quota_hash[:quota] - quota_hash[:quota_used]
    end
  end

  # since the central directory can lie, track quota during extraction as well
  # to prevent zip bomb denial-of-service attacks
  def charge_quota(size)
    return if @quota_remaining.nil?
    if size > @quota_remaining
      raise Attachment::OverQuotaError, "Zip contents exceed course quota limit"
    end

    @quota_remaining -= size
  end

  def paths_with_positions(base)
    positions_hash = {}
    paths.sort.each_with_index { |p, idx| positions_hash[p] = idx + base }
    positions_hash
  end

  def percent_complete(current_index)
    (current_index + 1).to_f / file_count.to_f
  end

  private

  def process!
    CanvasUnzip.extract_archive(filename) do |entry|
      @file_count += 1
      @total_size += [entry.size, Attachment::MINIMUM_SIZE_FOR_QUOTA].max
      @paths << entry.name
    end
    @file_count = 1 if @file_count == 0
  end
end
