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

describe ContentZipper do
  before do
    local_storage!
  end

  describe "zip_assignment" do
    it "processes user names" do
      s1, s2, s3, s4 = n_students_in_course(4)
      s1.update_attribute :sortable_name, "some_999_, _1234_guy"
      s2.update_attribute :sortable_name, "other 567, guy 8"
      s3.update_attribute :sortable_name, "trolololo"
      s4.update_attribute :sortable_name, "ünicodemân"
      assignment_model(course: @course)
      [s1, s2, s3, s4].each do |s|
        submission_model user: s, assignment: @assignment, body: "blah"
      end
      attachment = Attachment.new(display_name: "my_download.zip")
      attachment.user = @teacher
      attachment.workflow_state = "to_be_zipped"
      attachment.context = @assignment
      attachment.save!
      ContentZipper.process_attachment(attachment, @teacher)
      expected_file_patterns = [
        /other567guy8/,
        /some9991234guy/,
        /trolololo/,
        /ünicodemân/
      ]

      filename = attachment.reload.full_filename

      Zip::File.foreach(filename) do |f|
        expect do
          expected_file_patterns.delete_if { |expected_pattern| f.name =~ expected_pattern }
        end.to change { expected_file_patterns.size }.by(-1)
      end

      expect(expected_file_patterns).to be_empty
    end

    context "anonymous assignments" do
      before(:once) do
        course = Course.create!
        student = User.create!(name: "fred")
        @teacher = User.create!
        course.enroll_student(student, enrollment_state: :active)
        course.enroll_teacher(@teacher, enrollment_state: :active)
        @assignment = course.assignments.create!(anonymous_grading: true, muted: true)
        @assignment.submit_homework(student, body: "homework")
        @attachment = @assignment.attachments.create!(
          display_name: "my_download.zip",
          user: @teacher,
          workflow_state: "to_be_zipped"
        )
      end

      it "omits user names if the assignment is anonymous and muted" do
        ContentZipper.process_attachment(@attachment, @teacher)
        Zip::File.open(@attachment.reload.full_filename) do |zip_file|
          filename = zip_file.first.name
          expect(filename).not_to match(/fred/)
        end
      end

      it "includes user names if the assignment is anonymous and unmuted" do
        @assignment.unmute!
        ContentZipper.process_attachment(@attachment, @teacher)
        Zip::File.open(@attachment.reload.full_filename) do |zip_file|
          filename = zip_file.first.name
          expect(filename).to match(/fred/)
        end
      end
    end

    it "ignores undownloadable submissions" do
      course_with_student(active_all: true)
      @user.update!(sortable_name: "some_999_, _1234_guy")
      assignment_model(course: @course)
      @assignment.submission_types = "online_text_entry,media_recording"
      @assignment.save
      my_media_object = media_object(context: @course, user: @user)
      submission = @assignment.submit_homework(@user, {
                                                 submission_type: "media_recording",
                                                 media_comment_id: my_media_object.media_id,
                                                 media_comment_type: my_media_object.media_type
                                               })
      submission.save

      attachment = Attachment.new(display_name: "my_download.zip")
      attachment.user = @teacher
      attachment.workflow_state = "to_be_zipped"
      attachment.context = @assignment
      attachment.save!
      ContentZipper.process_attachment(attachment, @teacher)
      attachment.reload

      zip_file = Zip::File.open(attachment.full_filename)
      expect(zip_file.entries).to be_empty
      zip_file.close
    end

    it "zips up online_url submissions" do
      course_with_student(active_all: true)
      @user.update!(sortable_name: "some_999_, _1234_guy")
      submission_model user: @user
      attachment = Attachment.new(display_name: "my_download.zip")
      attachment.user = @teacher
      attachment.workflow_state = "to_be_zipped"
      attachment.context = @assignment
      attachment.save!
      ContentZipper.process_attachment(attachment, @teacher)
      attachment.reload
      expect(attachment.workflow_state).to eq "zipped"
      Zip::File.foreach(attachment.full_filename) do |f|
        if f.file?
          expect(f.name).to match(/some9991234guy/)
          expect(f.get_input_stream.read).to match(/This submission was a url/)
          expect(f.get_input_stream.read).to include("http://www.instructure.com/")
        end
      end
    end

    it "zips up online_text_entry submissions" do
      course_with_student(active_all: true)
      @student.update_attribute(:name, "some student name")
      submission_model(body: "hai this is my answer")
      attachment = Attachment.new(display_name: "my_download.zip")
      attachment.user = @teacher
      attachment.workflow_state = "to_be_zipped"
      attachment.context = @assignment
      attachment.save!
      @teacher.time_zone = ActiveSupport::TimeZone["Eastern Time (US & Canada)"]
      @teacher.save!(validate: false)
      @teacher.reload
      ContentZipper.process_attachment(attachment, @teacher)
      attachment.reload
      expect(attachment.workflow_state).to eq "zipped"

      content = nil
      Zip::File.foreach(attachment.full_filename) do |f|
        now_utc = Zip::DOSTime.from_time(Time.use_zone("Eastern Time (US & Canada)") { Time.now.utc })
        expect(f.time).to be_within(1.second).of(now_utc)
        content = f.get_input_stream.read if f.file?
      end
      expect(content).to include("hai this is my answer")
      expect(content).to include(@student.name)
    end

    it "does not include student name in online_text_entry submissions if anonymous" do
      course_with_student(active_all: true)
      @student.update_attribute(:name, "some student name")

      @assignment = @course.assignments.create!(anonymous_grading: true, muted: true)
      submission_model(body: "hai this is my answer", assignment: @assignment, user: @student)
      attachment = Attachment.create!(display_name: "my_download.zip",
                                      user: @teacher,
                                      workflow_state: "to_be_zipped",
                                      context: @assignment)
      ContentZipper.process_attachment(attachment, @teacher)
      attachment.reload
      content = nil
      Zip::File.foreach(attachment.full_filename) do |f|
        content = f.get_input_stream.read if f.file?
      end
      expect(content).to include("hai this is my answer")
      expect(content).to_not include(@student.name)
      expect(content).to include("Anonymous User")
    end

    it "only includes submissions in the correct section" do
      course_with_student(active_all: true)
      submission_model(body: "hai this is my answer")
      @section = @course.course_sections.create!
      @ta = user_with_pseudonym(active_all: 1)
      @course.enroll_user(@ta, "TaEnrollment", limit_privileges_to_course_section: true, section: @section)
      attachment = Attachment.new(display_name: "my_download.zip")
      attachment.user = @ta
      attachment.workflow_state = "to_be_zipped"
      attachment.context = @assignment
      attachment.save!
      ContentZipper.process_attachment(attachment, @ta)
      attachment.reload
      submission_count = 0
      # no submissions
      Zip::File.foreach(attachment.full_filename) do
        submission_count += 1
      end

      expect(submission_count).to eq 0
    end

    it "only includes one submission per group" do
      teacher_in_course active_all: true
      gc = @course.group_categories.create! name: "Homework Groups"
      groups = Array.new(2) { |i| gc.groups.create! name: "Group #{i}", context: @course }
      students = Array.new(4) do
        student_in_course(active_all: true)
        @student
      end
      students.each_with_index { |s, i| groups[i % groups.size].add_user(s) }
      a = @course.assignments.create! group_category_id: gc.id,
                                      grade_group_students_individually: false,
                                      submission_types: %w[text_entry]
      a.submit_homework(students.first, body: "group 1 submission")
      a.submit_homework(students.second, body: "group 2 submission")

      attachment = Attachment.new(display_name: "my_download.zip")
      attachment.user = @teacher
      attachment.workflow_state = "to_be_zipped"
      attachment.context = a
      attachment.save!

      ContentZipper.process_attachment(attachment, @teacher)
      expected_file_names = [/group0/, /group1/]
      Zip::File.foreach(attachment.full_filename) do |f|
        expect do
          expected_file_names.delete_if { |expected_name| f.name =~ expected_name }
        end.to change { expected_file_names.size }.by(-1)
      end
    end

    it "excludes deleted attachments" do
      course_with_student(active_all: true)

      assignment = assignment_model(course: @course)
      att = attachment_model(uploaded_data: stub_file_data("test.txt", "asdf", "text/plain"), context: @student)
      submission_model(user: @student, assignment:, attachments: [att])
      att.destroy

      attachment = Attachment.new(display_name: "my_download.zip")
      attachment.user = @teacher
      attachment.workflow_state = "to_be_zipped"
      attachment.context = assignment
      attachment.save!

      ContentZipper.process_attachment(attachment, @teacher)
      expect(Zip::File.new(attachment.open).entries.count).to eq 0
    end

    it "strips harmful characters from submission filenames" do
      course_with_student(active_all: true)

      assignment = assignment_model(course: @course)
      att = attachment_model(uploaded_data: stub_file_data("A/V??.txt", "a/v", "text/plain"), context: @student)
      submission_model(user: @student, assignment:, attachments: [att])

      attachment = Attachment.new(display_name: "my_download.zip")
      attachment.user = @teacher
      attachment.workflow_state = "to_be_zipped"
      attachment.context = assignment
      attachment.save!

      ContentZipper.process_attachment(attachment, @teacher)
      entry = Zip::File.new(attachment.open).entries.first
      expect(entry.name).to end_with "A_V_.txt"
    end
  end

  describe "assignment_zip_filename" do
    it "uses use course and title slugs to keep filename length down" do
      course_factory(active_all: true)
      @course.short_name = "a" * 31
      @course.save!
      assignment_model(course: @course, title: "b" * 31)

      zipper = ContentZipper.new
      filename = zipper.assignment_zip_filename(@assignment)
      expect(filename).to match(/#{@course.short_name_slug}/)
      expect(filename).to match(/#{@assignment.title_slug}/)
      expect(filename).not_to match(/#{@course.short_name}/)
      expect(filename).not_to match(/#{@assignment.title}/)
    end
  end

  describe "hard concluded course submissions" do
    it "still downloads the content" do
      course_with_teacher
      @assignment = assignment_model(course: @course)
      5.times do |i|
        attachment = attachment_model(uploaded_data: stub_png_data("file_#{i}.png"), content_type: "image/png")
        submission_model(course: @course, assignment: @assignment, submission_type: "online_upload", attachments: [attachment])
      end
      @course.complete
      @course.save!

      @course.reload
      @assignment.reload

      zipper = ContentZipper.new
      attachment = Attachment.new(display_name: "my_download.zip")
      attachment.user_id = @user.id
      attachment.workflow_state = "to_be_zipped"
      attachment.context = @assignment
      attachment.save!
      zipper.process_attachment(attachment, @user)

      attachment.reload
      expect(attachment.workflow_state).to eq "zipped"
      f = File.new(attachment.full_filename)
      expect(f.size).to be > 22 # the characteristic size of an empty zip file
    end
  end

  describe "zip_folder" do
    context "checking permissions" do
      before do
        course_with_student(active_all: true)
        folder = Folder.root_folders(@course).first
        attachment_model(uploaded_data: stub_png_data("hidden.png"),
                         content_type: "image/png",
                         hidden: true,
                         folder:)
        attachment_model(uploaded_data: stub_png_data("visible.png"),
                         content_type: "image/png",
                         folder:)
        attachment_model(uploaded_data: stub_png_data("locked.png"),
                         content_type: "image/png",
                         folder:,
                         locked: true)
        hidden_folder = folder.sub_folders.create!(context: @course, name: "hidden", hidden: true)
        visible_folder = folder.sub_folders.create!(context: @course, name: "visible")
        locked_folder = folder.sub_folders.create!(context: @course, name: "locked", locked: true)
        attachment_model(uploaded_data: stub_png_data("sub-hidden.png"),
                         content_type: "image/png",
                         folder: hidden_folder)
        attachment_model(uploaded_data: stub_png_data("sub-vis.png"),
                         content_type: "image/png",
                         folder: visible_folder)
        attachment_model(uploaded_data: stub_png_data("sub-locked.png"),
                         content_type: "image/png",
                         folder: visible_folder,
                         locked: true)
        attachment_model(uploaded_data: stub_png_data("sub-locked-vis.png"),
                         content_type: "image/png",
                         folder: locked_folder)

        @attachment = Attachment.new(display_name: "my_download.zip")
        @attachment.workflow_state = "to_be_zipped"
        @attachment.context = folder.reload
      end

      let(:visible_files) do
        ["visible.png", "visible/sub-vis.png"].sort
      end

      let(:all_files) do
        (visible_files + ["locked/sub-locked-vis.png", "hidden/sub-hidden.png", "hidden.png", "visible/sub-locked.png", "locked.png"]).sort
      end

      def zipped_files_for_user(user = nil, check_user = true)
        @attachment.user_id = user.id if user
        @attachment.save!
        ContentZipper.process_attachment(@attachment, user, check_user:)
        names = []
        @attachment.reload
        Zip::File.foreach(@attachment.full_filename) { |f| names << f.name if f.file? }
        names.sort
      end

      context "in course with files tab hidden" do
        before do
          @course.tab_configuration = [{
            id: Course::TAB_FILES,
            hidden: true
          }]
          @course.save
        end

        it "gives logged in students visible files" do
          expect(zipped_files_for_user(@user)).to eq visible_files
        end

        context("for a logged in teacher with a concluded enrollment") do
          it "gives the teacher all files" do
            concluded_teacher = User.create!
            @course.enroll_teacher(concluded_teacher, enrollment_state: :completed)
            expect(zipped_files_for_user(concluded_teacher)).to eq all_files
          end
        end

        it "gives logged in teachers all files" do
          expect(zipped_files_for_user(@teacher)).to eq all_files
        end
      end

      context "in a private course" do
        it "gives logged in students visible files" do
          expect(zipped_files_for_user(@user)).to eq visible_files
        end

        it "gives logged in teachers all files" do
          expect(zipped_files_for_user(@teacher)).to eq all_files
        end

        it "gives logged out people no files" do
          expect(zipped_files_for_user(nil)).to eq []
        end

        it "gives all files if check_user=false" do
          expect(zipped_files_for_user(nil, false)).to eq all_files
        end
      end

      context "in a public course" do
        before do
          @course.is_public = true
          @course.save!
        end

        it "gives logged in students visible files" do
          expect(zipped_files_for_user(@user)).to eq visible_files
        end

        it "gives logged in teachers all files" do
          expect(zipped_files_for_user(@teacher)).to eq all_files
        end

        it "gives logged out people visible files" do
          expect(zipped_files_for_user(nil)).to eq visible_files
        end

        it "gives all files if check_user=false" do
          expect(zipped_files_for_user(nil, false)).to eq all_files
        end
      end
    end

    it "does not error on empty folders" do
      course_with_student(active_all: true)
      folder = Folder.root_folders(@course).first
      attachment = Attachment.new(display_name: "my_download.zip")
      attachment.user_id = @user.id
      attachment.workflow_state = "to_be_zipped"
      attachment.context = folder
      attachment.save!
      ContentZipper.process_attachment(attachment, @user)
      expect(attachment.workflow_state).to eq "zipped"
    end

    describe "error handling" do
      before :once do
        course_with_student(active_all: true)
        @root = Folder.root_folders(@course).first
        @bad_file = @course.attachments.create!(folder: @root, uploaded_data: StringIO.new("bad"), filename: "bad")
        @bad_file.update_attribute(:filename, "not the real filename try and open this now sucka")
        @attachment = Attachment.new(display_name: "my_download.zip")
        @attachment.user_id = @user.id
        @attachment.workflow_state = "to_be_zipped"
        @attachment.context = @root
        @attachment.save!
      end

      it "errors if no files could be added" do
        ContentZipper.process_attachment(@attachment, @user)
        expect(@attachment.workflow_state).to eq "errored"
      end

      it "skips files that couldn't be opened, without failing the download" do
        @course.attachments.create!(folder: @root, uploaded_data: StringIO.new("good"), filename: "good")
        @attachment.reload
        ContentZipper.process_attachment(@attachment, @user)
        @course.attachments.reload
        expect(@attachment.workflow_state).to eq "zipped"
        expect(Zip::File.new(@attachment.full_filename).entries.map(&:name)).to eq ["good"]
      end
    end

    it "uses the display name" do
      course_with_student(active_all: true)
      folder = Folder.root_folders(@course).first
      attachment_model(uploaded_data: stub_png_data("hidden.png"),
                       content_type: "image/png",
                       folder:,
                       display_name: "otherfile.png")
      attachment = Attachment.new(display_name: "my_download.zip")
      attachment.user_id = @user.id
      attachment.workflow_state = "to_be_zipped"
      attachment.context = folder
      attachment.save!
      ContentZipper.process_attachment(attachment, @user)
      attachment.reload
      names = []
      Zip::File.foreach(attachment.full_filename) { |f| names << f.name if f.file? }
      expect(names).to eq ["otherfile.png"]
    end
  end

  describe "mark_successful!" do
    it "sets an instance variable representing a successful zipping" do
      zipper = ContentZipper.new
      expect(zipper).not_to be_zipped_successfully
      zipper.mark_successful!
      expect(zipper).to be_zipped_successfully
    end
  end

  describe "zip_eportfolio" do
    it "processes page entries with no content" do
      user = User.create!
      eportfolio = user.eportfolios.create!(name: "an name")
      eportfolio.ensure_defaults
      attachment = eportfolio.attachments.create!(
        display_name: "an_attachment",
        user:,
        workflow_state: "to_be_zipped"
      )
      expect do
        ContentZipper.new.zip_eportfolio(attachment, eportfolio)
      end.to_not raise_error
    end

    context "with restricted permissions" do
      before do
        course_with_student(active_all: true)
        folder = Folder.root_folders(@course).first
        attachment_model(uploaded_data: stub_png_data("hidden.png"),
                         content_type: "image/png",
                         folder:,
                         display_name: "hidden.png")
      end

      let(:eportfolio) do
        eportfolio = @user.eportfolios.create!(name: "an name")
        eportfolio.ensure_defaults
        entry = eportfolio.eportfolio_entries.first
        entry.parse_content({ section_count: 1, section_1: { section_type: "rich_text", content: "/files/#{@attachment.id}/download" } })
        entry.save!
        eportfolio
      end

      let(:zipped_file) do
        eportfolio.reload
        eportfolio.attachments.create do |attachment|
          attachment.display_name = "an_attachment"
          attachment.user = @user
          attachment.workflow_state = "to_be_zipped"
        end
      end

      let(:zipped_filenames) { Zip::File.new(zipped_file.full_filename).entries.map(&:name) }

      it "does not process attachments that user cannot see" do
        @user = User.create!
        ContentZipper.new.zip_eportfolio(zipped_file, eportfolio)
        expect(zipped_filenames).not_to include a_string_matching(/hidden.png/)
      end

      it "does not process attachments that user cannot download" do
        @user = @student
        @attachment.update! locked: true
        ContentZipper.new.zip_eportfolio(zipped_file, eportfolio)
        expect(zipped_filenames).not_to include a_string_matching(/hidden.png/)
      end

      it "does process attachments that user can download" do
        @user = @student
        ContentZipper.new.zip_eportfolio(zipped_file, eportfolio)
        zipped_file.reload
        expect(zipped_filenames).to include a_string_matching(/hidden.png/)
      end
    end

    it "processes the zip file name" do
      user = User.create!
      eportfolio = user.eportfolios.create!(name: "/../../etc/passwd")

      attachment = Attachment.new(display_name: "my_download.zip")
      attachment.user = user
      attachment.workflow_state = "to_be_zipped"
      attachment.context = eportfolio
      attachment.save!
      expect(Dir).to receive(:mktmpdir).once.and_yield("/tmp")
      expect(Zip::File).to receive(:open).once.with("/tmp/etcpasswd.zip", Zip::File::CREATE)
      ContentZipper.process_attachment(attachment, user)
    end
  end

  describe "render_eportfolio_page_content" do
    it "returns the text of the file contents" do
      user = User.create!
      eportfolio = user.eportfolios.create!(name: "bestest_eportfolio_eva")
      eportfolio.ensure_defaults

      contents = ContentZipper.new.render_eportfolio_page_content(eportfolio.eportfolio_entries.first, eportfolio, nil, {})
      expect(contents).to match("bestest_eportfolio_eva") # really just testing that this method doesn't throw an error
    end
  end

  describe "mark_attachment_as_zipping!" do
    it "marks the workflow state as zipping" do
      attachment = Attachment.new display_name: "jenkins.ppt"
      expect(attachment).to receive(:save!).once
      ContentZipper.new.mark_attachment_as_zipping!(attachment)
      expect(attachment).to be_zipping
    end
  end

  describe "update_progress" do
    it "updates the zip attachment's state to a percentage and save!s it" do
      attachment = Attachment.new display_name: "donuts.jpg"
      expect(attachment).to receive(:save!).once
      ContentZipper.new.update_progress(attachment, 5, 10)
      expect(attachment.file_state.to_s).to eq "60" # accounts for zero-indexed arrays
    end
  end

  describe "complete_attachment" do
    before { @attachment = Attachment.new display_name: "I <3 testing.png" }

    context "when attachment wasn't zipped successfully" do
      it "moves the zip attachment into an error state and save!s it" do
        expect(@attachment).to receive(:save!).once
        ContentZipper.new.complete_attachment!(@attachment, "hello")
        expect(@attachment.workflow_state).to eq "errored"
      end
    end

    context "attachment was zipped successfully" do
      it "creates uploaded data for the assignment and marks it as available" do
        expect(@attachment).to receive(:save!).once
        zip_name = "submissions.zip"
        zip_path = file_fixture(zip_name)
        data = "just some stub data"
        expect(Canvas::UploadedFile).to receive(:new).with(zip_path, "application/zip").and_return data
        expect(@attachment).to receive(:uploaded_data=).with data
        zipper = ContentZipper.new
        zipper.mark_successful!
        zipper.complete_attachment!(@attachment, zip_path)
        expect(@attachment).to be_zipped
        expect(@attachment.file_state).to eq "available"
      end
    end
  end

  describe "zip_quiz" do
    it "delegates to a QuizSubmissionZipper" do
      course_with_teacher(active_all: true)
      attachment = Attachment.new(display_name: "download.zip")
      quiz = Quizzes::Quiz.new(context: @course)
      zipper_stub = double
      expect(zipper_stub).to receive(:zip!).once
      attachment.context = quiz
      expect(Quizzes::QuizSubmissionZipper).to receive(:new).with(
        quiz:,
        zip_attachment: attachment
      ).and_return zipper_stub
      ContentZipper.process_attachment(attachment, quiz)
    end
  end
end
