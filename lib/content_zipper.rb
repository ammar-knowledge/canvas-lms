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
require "zip"

class ContentZipper
  MAX_FILENAME_LENGTH = 255

  def initialize(options = {})
    @check_user = options.key?(:check_user) ? options[:check_user] : true
    @logger = Rails.logger
  end
  attr_writer :user

  # we evaluate some ERB templates from under app/views/ while generating assignment zips
  include I18nUtilities
  def t(...)
    I18n.t(...)
  end

  def self.process_attachment(*args)
    options = args.last.is_a?(Hash) ? args.pop : {}
    ContentZipper.new(options).process_attachment(*args)
  end

  def process_attachment(attachment, user = nil)
    raise "No attachment provided to ContentZipper.process_attachment" unless attachment

    attachment.update_attribute(:workflow_state, "zipping")
    @user = user
    @logger.debug("file found: #{attachment.id} zipping files...")

    begin
      case attachment.context
      when Assignment then zip_assignment(attachment, attachment.context)
      when Eportfolio then zip_eportfolio(attachment, attachment.context)
      when Folder then zip_base_folder(attachment, attachment.context)
      when Quizzes::Quiz then zip_quiz(attachment, attachment.context)
      end
    rescue => e
      Canvas::Errors.capture(e, { message: "Content zipping failed" }, :warn)
      attachment.update_attribute(:workflow_state, "to_be_zipped")
    end
  end

  def assignment_zip_filename(assignment)
    "#{assignment.context.short_name_slug}-#{assignment.title_slug} submissions"
  end

  def zip_assignment(zip_attachment, assignment)
    mark_attachment_as_zipping!(zip_attachment)

    @assignment = assignment
    @context    = assignment.context

    filename = assignment_zip_filename(assignment)
    @user = user = zip_attachment.user

    # It is possible to get this far if an assignment allows the
    # downloadable submissions below as well as those that can't be
    # downloaded. In that case, only retrieve the ones that can be
    # downloaded.
    downloadable_submissions = %w[online_upload online_url online_text_entry]
    if @context.completed?
      submissions = assignment.submissions.where(submission_type: downloadable_submissions)
      # This neglects the complexity of group assignments
      students = User.where(id: submissions.pluck(:user_id)).index_by(&:id)
    else
      students    = assignment.representatives(user:).index_by(&:id)
      submissions = assignment.submissions.where(user_id: students.keys,
                                                 submission_type: downloadable_submissions)
    end

    @tempfiles = []

    make_zip_tmpdir(filename) do |zip_name|
      @logger.debug("creating #{zip_name}")
      Zip::File.open(zip_name, Zip::File::CREATE) do |zipfile|
        count = submissions.length
        # prevents browser hangs when there are no submissions to download
        mark_successful! if count == 0

        submissions.each_with_index do |submission, index|
          add_submission(submission, students, zipfile)
          update_progress(zip_attachment, index, count)
        end
      end

      @tempfiles.each do |tempfile|
        tempfile.close
        tempfile.unlink
      end

      @logger.debug("added #{submissions.size} submissions")
      assignment.increment!(:submissions_downloads)
      complete_attachment!(zip_attachment, zip_name)
    end
  end

  class StaticAttachment
    attr_accessor :display_name,
                  :filename,
                  :unencoded_filename,
                  :content_type,
                  :uuid,
                  :id,
                  :attachment

    # Match on /files URLs capturing the object id.
    FILES_REGEX = %r{/files/(?<obj_id>\d+)/\w+(?:(?:[^\s"<'?/]*)(?:[^\s"<']*))?}

    def initialize(attachment, index = nil)
      @attachment = attachment

      @display_name = @attachment.display_name
      @filename = index ? "#{index}_#{@attachment.filename}" : @attachment.filename
      @unencoded_filename = index ? "#{index}_#{@attachment.unencoded_filename}" : @attachment.unencoded_filename
      @content_type = @attachment.content_type
      @uuid = @attachment.uuid
      @id = @attachment.id
    end
  end

  def zip_eportfolio(zip_attachment, portfolio)
    static_attachments = []
    rich_text_attachments = []
    submissions = []

    portfolio_entries = portfolio.eportfolio_entries

    index = 1
    portfolio_entries.each do |entry|
      entry.readonly!

      index = rewrite_eportfolio_richtext_entry(index, rich_text_attachments, entry, zip_attachment.user)

      static_attachments += entry.attachments.select { |x| x.grants_right?(zip_attachment.user, :download) }
      submissions += entry.submissions
    end

    submissions_hash = {}
    submissions.each do |s|
      submissions_hash[s.id] = s
      if s.submission_type == "online_upload"
        static_attachments += s.attachments
      end
    end
    static_attachments = static_attachments.uniq.map do |a|
      obj = StaticAttachment.new(a, index)
      index += 1
      obj
    end

    all_attachments = rich_text_attachments + static_attachments

    make_zip_tmpdir(portfolio.name) do |zip_name|
      index = 0
      count = all_attachments.length + 2
      Zip::File.open(zip_name, Zip::File::CREATE) do |zipfile|
        update_progress(zip_attachment, index, count)
        portfolio_entries.each do |entry|
          # if filename > 180 characters (allows 75 character buffer for the unique slug)
          filename = Attachment.shorten_filename(entry.full_slug.concat(".html"))
          content = render_eportfolio_page_content(entry, portfolio, all_attachments, submissions_hash)
          zipfile.get_output_stream(filename) { |f| f.puts content }
        end
        update_progress(zip_attachment, index, count)
        all_attachments.each do |a|
          add_attachment_to_zip(a.attachment, zipfile, a.unencoded_filename)
          update_progress(zip_attachment, index, count)
        end
        zipfile.add("eportfolio.css", Rails.root.join("app/stylesheets/eportfolio_static.css"))
        zipfile.add("logo.svg", Rails.public_path.join("images/canvas-logo.svg"))
      end
      mark_successful!
      complete_attachment!(zip_attachment, zip_name)
    end
  end

  def render_eportfolio_page_content(page, portfolio, static_attachments, submissions_hash)
    @page = page
    @static_attachments = static_attachments
    @submissions_hash = submissions_hash

    ApplicationController.render(
      partial: "eportfolios/static_page",
      locals: { page:, portfolio:, static_attachments:, submissions_hash: }
    )
  end

  def self.zip_base_folder(*)
    ContentZipper.new.zip_base_folder(*)
  end

  def zip_base_folder(zip_attachment, folder)
    # this file count is admittedly an upper bound; not all files may be selected, and I don't want to count the ones
    # that are, but this will provide visible progress on large jobs, where it's most needed
    @zip_attachment = zip_attachment
    @file_count = folder.context.attachments.not_deleted.count
    @files_added = nil
    @logger.debug("zipping into attachment: #{zip_attachment.id}")
    zip_attachment.workflow_state = "zipping" # !(:workflow_state => 'zipping')
    zip_attachment.save!
    filename = "#{folder.context.short_name}-#{folder.name} files"
    make_zip_tmpdir(filename) do |zip_name|
      @logger.debug("creating #{zip_name}")
      Zip::File.open(zip_name, Zip::File::CREATE) do |zipfile|
        @logger.debug("zip_name: #{zip_name}")
        process_folder(folder, zipfile)
      end
      mark_successful! unless @files_added == false
      complete_attachment!(zip_attachment, zip_name)
    end
  end

  def process_folder(folder, zipfile, start_dirs = [], opts = {}, &callback)
    if callback
      zip_folder(folder, zipfile, start_dirs, opts, &callback)
    else
      zip_folder(folder, zipfile, start_dirs, opts)
    end
  end

  # make a tmp directory and yield a filename under that directory to the block
  # given. the tmp directory is deleted when the block returns.
  def make_zip_tmpdir(filename)
    filename = File.basename(filename.tr(" ", "_").gsub(/[^\w-]/, ""))
    Dir.mktmpdir do |dirname|
      zip_name = File.join(dirname, "#{filename}.zip")
      yield zip_name
    end
  end

  def folder_attachments_for_export(folder, opts)
    # @user = nil either means that
    # 1. this is part of a public course, and is being downloaded by somebody
    # not logged in - OR -
    # 2. we're doing this inside a course context export, and are bypassing
    # the user check (@check_user == false)
    attachments =
      if !@check_user || folder.context.grants_any_right?(@user, :read_as_admin, :manage_contents, *RoleOverride::GRANULAR_FILE_PERMISSIONS)
        folder.active_file_attachments
      else
        folder.visible_file_attachments
      end

    attachments = attachments.select { |a| opts[:exporter].export_object?(a, ignore_updated_at: opts[:ignore_updated_at]) } if opts[:exporter]
    attachments = attachments.select { |a| !@check_user || a.grants_right?(@user, :download) }
    attachments.reject do |attachment|
      # exclude files in hidden folders unless they're referenced in rich content (or the user is an admin)
      @check_user && folder.hidden? &&
        !folder.grants_right?(@user, :read_contents) && !opts[:referenced_files]&.key?(attachment.id)
    end
  end

  # The callback should accept two arguments, the attachment/folder and the folder names
  def zip_folder(folder, zipfile, folder_names, opts = {}, &block)
    if block && (folder.hidden? || folder.locked)
      yield(folder, folder_names)
    end
    folder_attachments_for_export(folder, opts).each do |attachment|
      attachment.display_name = Attachment.shorten_filename(attachment.display_name)
      # Preventing further unwanted filename alterations during the rest of the process,
      # namely, in the block further below. Also, we want to avoid accidental saving of the file
      # with the shortened name
      attachment.readonly!
      path = folder_names.empty? ? attachment.display_name : File.join(folder_names, attachment.display_name)
      yield(attachment, folder_names) if block
      @context = folder.context
      @logger.debug("  found attachment: #{attachment.unencoded_filename}")
      if add_attachment_to_zip(attachment, zipfile, path)
        @files_added ||= 0
        @files_added += 1
        update_progress(@zip_attachment, @files_added, @file_count) if @zip_attachment
      elsif @files_added.nil?
        @files_added = false
      end
    end
    folder.active_sub_folders.select do |f|
      !@check_user || f.grants_right?(@user, :read_contents_for_export)
    end.each do |sub_folder|
      new_names = Array.new(folder_names) << sub_folder.name
      zip_folder(sub_folder, zipfile, new_names, opts, &block)
    end
  end

  def mark_attachment_as_zipping!(zip_attachment)
    zip_attachment.workflow_state = "zipping"
    zip_attachment.save!
  end

  def zip_quiz(zip_attachment, quiz)
    Quizzes::QuizSubmissionZipper.new(
      quiz:,
      zip_attachment:
    ).zip!
  end

  def mark_successful!
    @zip_successful = true
  end

  def zipped_successfully?
    !!@zip_successful
  end

  def add_attachment_to_zip(attachment, zipfile, filename = nil)
    filename ||= attachment.filename

    @files_in_zip ||= Set.new
    # if filename > 180 characters (allows 75 character buffer for the unique filename)
    filename = Attachment.shorten_filename(filename)
    # we allow duplicate filenames in the same folder. it's a bit silly, but we
    # have to handle it here or people might not get all their files zipped up.
    filename = Attachment.make_unique_filename(filename, @files_in_zip)
    @files_in_zip << filename

    handle = nil
    begin
      handle = attachment.open
      handle.rewind if handle.respond_to?(:rewind)

      tempfile = Tempfile.new([File.basename(filename), File.extname(filename)])
      tempfile.binmode
      IO.copy_stream(handle, tempfile)
      tempfile.flush
      tempfile.rewind

      entry = Zip::Entry.new(zipfile.name, filename)
      Time.use_zone(@user&.time_zone || Time.zone) do
        entry.time = Zip::DOSTime.from_time(Time.now.utc)
      end
      zipfile.add(entry, tempfile.path)
      mark_successful!
    rescue Attachment::FailedResponse, Net::ReadTimeout, Net::OpenTimeout => e
      Canvas::Errors.capture_exception(:content_export, e, :warn)
      @logger.error("  skipping #{attachment.full_filename} with error: #{e.message}")
      return false
    rescue => e
      Canvas::Errors.capture_exception(:content_export, e, :error)
      @logger.error("  skipping #{attachment.full_filename} with error: #{e.message}")
      return false
    ensure
      handle&.close
    end

    true
  end

  def update_progress(zip_attachment, index, count)
    return unless count && count > 0

    zip_attachment.file_state = ((index + 1).to_f / count.to_f * 100).to_i
    return unless zip_attachment.file_state_changed?

    zip_attachment.save!
    @logger.debug("status for #{zip_attachment.id} updated to #{zip_attachment.file_state}")
  end

  def complete_attachment!(zip_attachment, zip_name)
    if zipped_successfully?
      @logger.debug("data zipped! uploading to external store...")
      uploaded_data = Canvas::UploadedFile.new(zip_name, "application/zip")
      Attachments::Storage.store_for_attachment(zip_attachment, uploaded_data)
      zip_attachment.workflow_state = "zipped"
      zip_attachment.file_state = "available"
    else
      zip_attachment.workflow_state = "errored"
    end
    zip_attachment.save!
  end

  private

  def rewrite_eportfolio_richtext_entry(index, attachments, entry, user)
    # In each rich_text section, find any referenced images, replace
    # the text with the image name, and add the image to the
    # attachments to be downloaded. If the rich_text attachment
    # can't be found, don't modify the the HTML, live with the
    # broken link, but have a mostly correct zip file.
    #
    # All other attachments toss on the static attachment pile for
    # later processing.
    if entry.content.is_a?(Array) && entry.content.present?
      entry.content.select { |c| c.is_a?(Hash) && c[:section_type] == "rich_text" }.each do |rt|
        rt[:content].gsub!(StaticAttachment::FILES_REGEX) do |match|
          att = Attachment.find_by(id: Regexp.last_match(:obj_id))
          if att.nil? || !att.grants_right?(user, :download)
            match
          else
            sa = StaticAttachment.new(att, index)
            attachments << sa
            index += 1
            sa.unencoded_filename
          end
        end
      end
    end

    index
  end

  def add_file(attachment, zipfile, filename)
    mark_successful! if attachment.deleted? || add_attachment_to_zip(attachment, zipfile, filename)
  end

  def add_online_submission_content(filename, display_page, zipfile)
    extend(ApplicationHelper)

    content = File.read(File.join("app", "views", "assignments", display_page))
    content = ERB.new(content).result(binding)

    if content
      tempfile = Tempfile.new([File.basename(filename, ".html"), ".html"])
      begin
        tempfile.write(content)
        tempfile.flush
        tempfile.rewind

        entry = Zip::Entry.new(zipfile.name, filename)
        Time.use_zone(@user&.time_zone || Time.zone) do
          entry.time = Zip::DOSTime.from_time(Time.now.utc)
        end

        zipfile.add(entry, tempfile.path)
        @tempfiles << tempfile

        mark_successful!
      end
    end
  end

  def add_submission(submission, students, zipfile)
    @submission = submission
    @logger.debug(" checking submission for #{submission.user.id}")

    users_name = get_user_name(students, submission) unless @assignment.anonymize_students?
    filename = get_filename(users_name, submission)

    case submission.submission_type
    when "online_upload"
      add_upload_submission(submission, zipfile, filename)
    when "online_url"
      add_text_or_url(:url, zipfile, filename)
    when "online_text_entry"
      add_text_or_url(:text, zipfile, filename)
    end
  end

  def add_text_or_url(type, to_zip, called)
    case type
    when :text
      filename = "#{called}_text.html"
      display_page = "text_entry_page.html.erb"
    when :url
      filename = "#{called}_link.html"
      display_page = "redirect_page.html.erb"
    end

    add_online_submission_content(filename, display_page, to_zip)
  end

  def add_upload_submission(submission, zipfile, filename)
    uploaded_files = get_uploaded_files_from(submission)

    uploaded_files.each do |file|
      @logger.debug("  found attachment: #{file.display_name}")
      full_filename = "#{filename}_#{file.id}_#{sanitize_attachment_filename(file.display_name)}"

      add_file(file, zipfile, full_filename)
    end
  end

  def get_filename(users_name, submission)
    id = @assignment.anonymize_students? ? "anon_#{submission.anonymous_id}" : submission.user_id
    filename = [users_name, submission.late? ? "LATE" : nil, id].compact.join("_")
    sanitize_file_name(filename)
  end

  def get_uploaded_files_from(submission)
    # NOTE: not using #versioned_attachments or #attachments because
    # they do not include submissions for group assignments for anyone
    # but the original submitter of the group submission
    attachment_ids = submission.attachment_ids.try(:split, ",")
    submission.shard.activate { Attachment.where(id: Array.wrap(attachment_ids)) }
  end

  def get_user_name(students, submission)
    # pulling out of this hash to get group names for group assignments
    # and to avoid extra queries
    user_name = students[submission.user_id].sortable_name
    sanitize_user_name(user_name)
  end

  def sanitize_file_name(filename)
    filename.gsub(/[^[[:word:]]]/, "")
  end

  def sanitize_attachment_filename(filename)
    filename.gsub(%r{[\x00/\\:*?"<>|]+}, "_")
  end

  def sanitize_user_name(user_name)
    # necessary because we use /_\d+_/ to infer the user/attachment
    # ids when teachers upload graded submissions
    user_name.gsub!(/_(\d+)_/, '\1')
    user_name.gsub!(/^(\d+)$/, '\1')
    user_name.downcase
  end
end
