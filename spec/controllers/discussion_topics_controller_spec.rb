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

require "feedjira"
require_relative "../spec_helper"

describe DiscussionTopicsController do
  before :once do
    course_with_teacher(active_all: true)
    course_with_observer(active_all: true, course: @course)
    @observer_enrollment = @enrollment
    ta_in_course(active_all: true, course: @course)
    student_in_course(active_all: true, course: @course)
  end

  let(:now) { Time.zone.now.change(usec: 0) }

  def course_topic(opts = {})
    @topic = @course.discussion_topics.build(title: "some topic", pinned: opts.fetch(:pinned, false))
    user = opts[:user] || @user
    if user && !opts[:skip_set_user]
      @topic.user = user
    end

    if opts[:with_assignment]
      @topic.assignment = @course.assignments.build(submission_types: "discussion_topic", title: @topic.title)
      @topic.assignment.infer_times
      @topic.assignment.saved_by = :discussion_topic
    end

    @topic.save
    @topic.reload
    @topic
  end

  def topic_entry
    @entry = @topic.discussion_entries.create(message: "some message", user: @user)
  end

  def topic_params(course, opts = {})
    {
      course_id: course.id,
      title: "Topic Title",
      is_announcement: false,
      discussion_type: "side_comment",
      require_initial_post: true,
      podcast_has_student_posts: false,
      delayed_post_at: "",
      locked: true,
      lock_at: "",
      message: "Message",
      delay_posting: false,
      threaded: false,
      specific_sections: "all"
    }.merge(opts)
  end

  def assignment_params(course, opts = {})
    course.require_assignment_group
    {
      assignment: {
        points_possible: 1,
        grading_type: "points",
        assignment_group_id: @course.assignment_groups.first.id,
      }.merge(opts)
    }
  end

  def group_topic_params(group, opts = {})
    params = topic_params(group, opts)
    params[:group_id] = group.id
    params.delete(:course_id)
    params
  end

  describe "GET 'index'" do
    it "requires authorization" do
      get "index", params: { course_id: @course.id }
      assert_unauthorized
    end

    it "requires the course to be published for students" do
      @course.claim
      user_session(@student)
      get "index", params: { course_id: @course.id }
      assert_unauthorized
    end

    it "does not show announcements without :read_announcements" do
      @course.account.role_overrides.create!(permission: "read_announcements", role: student_role, enabled: false)
      get "index", params: { course_id: @course.id }
      assert_unauthorized
    end

    it "loads for :view_group_pages students" do
      @course.account.role_overrides.create!(
        role: student_role,
        permission: "view_group_pages",
        enabled: true
      )
      @group_category = @course.group_categories.create(name: "gc")
      @group = @course.groups.create!(group_category: @group_category)
      user_session(@student)

      get "index", params: { group_id: @group.id }
      expect(response).to be_successful
    end

    context "graded group discussion" do
      before do
        @course.account.role_overrides.create!(
          role: student_role,
          permission: "view_group_pages",
          enabled: true
        )

        group_discussion_assignment
        @child_topic = @topic.child_topics.first
        @child_topic.root_topic_id = @topic.id
        @group = @child_topic.context
        @group.add_user(@student)
        @assignment.only_visible_to_overrides = true
        @assignment.save!
      end

      it "returns graded and visible group discussions properly" do
        cs = @student.enrollments.first.course_section
        create_section_override_for_assignment(@assignment, { course_section: cs })

        user_session(@student)

        get "index", params: { group_id: @group.id }
        expect(response).to be_successful
        expect(assigns["topics"]).to include(@child_topic)
      end

      it "assigns the create permission if the term is concluded and course is open" do
        @course.update_attribute(:restrict_enrollments_to_course_dates, true)
        term = @course.account.enrollment_terms.create!(name: "mew", end_at: Time.now.utc - 1.minute)
        @course.enrollment_term = term
        @course.update_attribute(:conclude_at, Time.now.utc + 1.hour)
        @course.save!
        user_session(@teacher)

        get "index", params: { course_id: @course.id }

        expect(assigns[:js_env][:permissions][:create]).to be_truthy
      end

      it "does not assign the create permission if the term and course are concluded" do
        term = @course.account.enrollment_terms.create!(
          name: "mew",
          start_at: 6.months.ago(now),
          end_at: 1.month.ago(now)
        )
        @course.enrollment_term = term
        @course.update!(start_at: 5.months.ago(now), conclude_at: 2.months.ago(now))
        user_session(@teacher)

        get "index", params: { course_id: @course.id }

        expect(assigns[:js_env][:permissions][:create]).to be_falsy
      end

      it "does not return graded group discussions if a student has no visibility" do
        user_session(@student)

        get "index", params: { group_id: @group.id }
        expect(response).to be_successful
        expect(assigns["topics"]).not_to include(@child_topic)
      end

      it "redirects to correct mastery paths edit page" do
        user_session(@teacher)
        allow(ConditionalRelease::Service).to receive_messages(enabled_in_context?: true, env_for: { dummy: "value" })
        get :edit, params: { group_id: @group.id, id: @child_topic.id }
        redirect_path = "/courses/#{@course.id}/discussion_topics/#{@topic.id}/edit"
        expect(response).to redirect_to(redirect_path)
      end
    end

    context "only_announcement param is set to true" do
      before do
        @active_ann1 = @course.announcements.create!(title: "announcement1", message: "Test without lock_at or unlock_at set", user: @teacher)
        @active_ann2 = @course.announcements.create!(title: "announcement2", message: "Test with lock_at in thepast and unlock_at in the future", user: @teacher, unlock_at: 1.day.ago, lock_at: 1.day.from_now)
        @inactive_ann1 = @course.announcements.create!(title: "announcement3", message: "Test with both lock_at and unlock_at in the future", user: @teacher, unlock_at: 1.day.from_now, lock_at: 2.days.from_now)
        @inactive_ann2 = @course.announcements.create!(title: "announcement4", message: "Test with both lock_at and unlock_at in the past", user: @teacher, unlock_at: 2.days.ago, lock_at: 1.day.ago)

        user_session(@student)
      end

      it "returns the only active announcements for a student" do
        get :index, params: { course_id: @course.id, only_announcements: true }, format: :json
        expect(assigns["topics"].size).to eq(2)
        expect(assigns["topics"]).to include(@active_ann1)
        expect(assigns["topics"]).to include(@active_ann2)
        expect(assigns["topics"]).not_to include(@inactive_ann1)
        expect(assigns["topics"]).not_to include(@inactive_ann2)
      end

      it "returns both active and inactive announcements for a teacher" do
        user_session(@teacher)

        get :index, params: { course_id: @course.id, only_announcements: true }, format: :json
        expect(assigns["topics"].size).to eq(4)
        expect(assigns["topics"]).to include(@active_ann1)
        expect(assigns["topics"]).to include(@active_ann2)
        expect(assigns["topics"]).to include(@inactive_ann1)
        expect(assigns["topics"]).to include(@inactive_ann2)
      end

      it "allows the teacher to see the announcement even if it is locked in a concluded course" do
        @course.complete!
        user_session(@teacher)

        get :index, params: { course_id: @course.id, only_announcements: true }, format: :json
        expect(assigns["topics"].size).to eq(4)
        expect(assigns["topics"]).to include(@active_ann1)
        expect(assigns["topics"]).to include(@active_ann2)
        expect(assigns["topics"]).to include(@inactive_ann1)
        expect(assigns["topics"]).to include(@inactive_ann2)
      end
    end

    context "cross-sharding" do
      specs_require_sharding

      it "marks as read when viewed" do
        @shard1.activate do
          account = Account.create!(name: "Shard2 account")
          @course = account.courses.create!(name: "new_course", workflow_state: "available")
          # @student is defined outside and lives on the default shard.
          @course.enroll_user(@student, "StudentEnrollment", enrollment_state: "active")
          user_session(@student)
          course_topic(skip_set_user: true)
          @topic.publish!

          expect(@student.stream_item_instances.count).to eq 1
          sii = @student.stream_item_instances.take
          expect(sii.workflow_state).to eq "unread"
          expect(@topic.read_state(@student)).to eq "unread"

          get "show", params: { course_id: @course.id, id: @topic.id }

          expect(sii.reload.workflow_state).to eq "read"
          expect(@topic.reload.read_state(@student)).to eq "read"
        end
      end

      it "works with short global id format" do
        @topic = @course.discussion_topics.create!(title: "student topic", message: "Hello", user: @student)
        get "show", params: { course_id: @course.id, id: "#{@topic.shard.id}~#{@topic.id}" }
        expect(response).to have_http_status :found
      end

      it "returns the topic across shards" do
        @topic = @course.discussion_topics.create!(title: "student topic", message: "Hello", user: @student)
        user_session(@student)
        @shard1.activate do
          get "index", params: { course_id: @course.id }, format: :json
          expect(assigns[:topics]).to include(@topic)
        end

        @shard2.activate do
          get "index", params: { course_id: @course.id }, format: :json
          expect(assigns[:topics]).to include(@topic)
        end
      end

      context "un-graded section specific discussions" do
        before(:once) do
          @shard1.activate do
            @student = user_factory(active_all: true)
          end
          course_with_teacher(active_course: true)
          @course.enroll_student(@student, enrollment_state: "active")
          @section = @course.course_sections.create!(name: "test section")
          student_in_section(@section, user: @student)
          @topic = @course.discussion_topics.create!(user: @teacher, message: "hello my favorite section!")
          @topic.is_section_specific = true
          @topic.course_sections = [@section]
          @topic.save!
        end

        it "is visible to student" do
          user_session(@student)
          @shard1.activate do
            get "index", params: { course_id: @course }, format: :json
            parsed_json = json_parse(response.body)
            visible_ids_to_student = parsed_json.pluck("id")

            expect(response).to have_http_status(:success)
            expect(visible_ids_to_student).to include(@topic.id)
          end
        end

        it "is visible to teacher" do
          @shard1.activate do
            @account_admin = account_admin_user(account: @course.root_account)
          end
          @topic = @course.discussion_topics.create!(title: "student topic", message: "Hello", user: @account_admin)
          @topic.update!(only_visible_to_overrides: true)
          @topic.assignment_overrides.create!(set: @course_section)
          @shard2.activate do
            @teacher = user_factory(active_all: true)
          end
          Enrollment.limit_privileges_to_course_section!(@course, @teacher, true)
          @course.enroll_teacher(@teacher, section: @course_section, allow_multiple_enrollments: true).accept!

          user_session(@teacher)
          @shard2.activate do
            get "index", params: { course_id: @course }, format: :json
            parsed_json = json_parse(response.body)
            visible_ids_to_teacher = parsed_json.pluck("id")

            expect(@topic.visible_for?(@teacher)).to be_truthy
            expect(response).to have_http_status(:success)
            expect(visible_ids_to_teacher).to include(@topic.id)
          end
        end
      end
    end

    it "returns non-graded group discussions properly" do
      @course.account.role_overrides.create!(
        role: student_role,
        permission: "view_group_pages",
        enabled: true
      )

      group_category(context: @course)
      group_with_user(group_category: @group_category, user: @student, context: @course)
      @topic = @group.discussion_topics.create(title: "group topic")
      @topic.context = @group
      @topic.save!

      user_session(@student)

      get "index", params: { group_id: @group.id }
      expect(response).to be_successful
      expect(assigns["topics"]).to include(@topic)
    end

    it "non-graded group discussions include root data if json request" do
      delayed_post_time = 1.day.from_now
      lock_at_time = 2.days.from_now
      user_session(@teacher)
      group_topic = group_discussion_topic_model(
        context: @course, delayed_post_at: delayed_post_time, lock_at: lock_at_time
      )
      group_topic.save!
      group_id = group_topic.child_topics.first.group.id
      get "index", params: { group_id: }, format: :json
      expect(response).to be_successful
      parsed_json = json_parse(response.body)
      expect(parsed_json.length).to eq 1
      parsed_topic = parsed_json.first
      # barf
      expect(parsed_topic["delayed_post_at"].to_json).to eq delayed_post_time.to_json
      expect(parsed_topic["lock_at"].to_json).to eq lock_at_time.to_json
    end

    it "sets discussions reporting and anonymity when their flags are enabled" do
      @course.root_account.enable_feature! :discussions_reporting

      user_session(@teacher)
      get "index", params: { course_id: @course.id }
      expect(assigns[:js_env][:student_reporting_enabled]).to be(true)
      expect(assigns[:js_env][:discussion_anonymity_enabled]).to be(true)
      expect(assigns[:js_env][:FEATURE_FLAGS_URL]).to eq("/courses/#{@course.id}/settings#tab-features")
    end

    context "DIRECT_SHARE_ENABLED" do
      it "sets DIRECT_SHARE_ENABLED when allowed" do
        user_session(@teacher)
        get "index", params: { course_id: @course.id }
        expect(response).to be_successful
        expect(assigns[:js_env][:DIRECT_SHARE_ENABLED]).to be(true)
      end

      it "does not set DIRECT_SHARE_ENABLED when viewing a group" do
        user_session(@teacher)
        group = @course.groups.create!
        get "index", params: { group_id: group.id }
        expect(response).to be_successful
        expect(assigns[:js_env][:DIRECT_SHARE_ENABLED]).to be(false)
      end

      describe "with manage_course_content_add permission disabled" do
        before do
          RoleOverride.create!(context: @course.account, permission: "manage_course_content_add", role: teacher_role, enabled: false)
        end

        it "does not set DIRECT_SHARE_ENABLED if the course is active" do
          user_session(@teacher)

          get "index", params: { course_id: @course.id }
          expect(response).to be_successful
          expect(assigns[:js_env][:DIRECT_SHARE_ENABLED]).to be(false)
        end

        describe "when the course is concluded" do
          before do
            @course.complete!
          end

          it "sets DIRECT_SHARE_ENABLED when the user can use it" do
            user_session(@teacher)

            get "index", params: { course_id: @course.id }
            expect(response).to be_successful
            expect(assigns[:js_env][:DIRECT_SHARE_ENABLED]).to be(true)
          end

          it "does not set DIRECT_SHARE_ENABLED when the user can't use it" do
            user_session(@student)

            get "index", params: { course_id: @course.id }
            expect(response).to be_successful
            expect(assigns[:js_env][:DIRECT_SHARE_ENABLED]).to be(false)
          end
        end
      end
    end

    describe "Metrics for the index page" do
      before do
        allow(InstStatsd::Statsd).to receive(:distributed_increment)
        allow(InstStatsd::Statsd).to receive(:count)
      end

      it "count discussion_topic.index.visit" do
        user_session(@teacher)
        get "index", params: { course_id: @course.id }
        expect(InstStatsd::Statsd).to have_received(:distributed_increment).with("discussion_topic.index.visit").at_least(:once)
      end

      it "count number of pinned discussions discussion_topic.index.pinned" do
        user_session(@teacher)
        get "index", params: { course_id: @course.id }
        expect(InstStatsd::Statsd).to have_received(:count).with("discussion_topic.index.visit.pinned", 0).at_least(:once)
      end

      it "count number of discussion_topic.index.visit.discussions" do
        user_session(@teacher)
        get "index", params: { course_id: @course.id }
        expect(InstStatsd::Statsd).to have_received(:count).with("discussion_topic.index.visit.discussions", 0).at_least(:once)
      end

      it "count number of discussion_topic.index.visit.closed_for_comments" do
        user_session(@teacher)
        get "index", params: { course_id: @course.id }
        expect(InstStatsd::Statsd).to have_received(:count).with("discussion_topic.index.visit.closed_for_comments", 0).at_least(:once)
      end
    end

    describe "differentiated modules" do
      context "ungraded discussions" do
        before do
          setup_course_and_users
          setup_discussion_topics
        end

        it "shows only assigned topics" do
          assign_topic_to_student(@topic, @student1)

          user_session(@student2)
          get "index", params: { course_id: @course.id }, format: :json
          parsed_json = json_parse(response.body)
          visible_ids_to_student_2 = parsed_json.pluck("id")

          expect(response).to have_http_status(:success)
          expect(visible_ids_to_student_2).to include(@topic_visible_to_everyone.id)
          expect(visible_ids_to_student_2).not_to include(@topic.id)

          user_session(@student1)
          get "index", params: { course_id: @course.id }, format: :json
          parsed_json = json_parse(response.body)
          visible_ids_to_student_1 = parsed_json.pluck("id")

          expect(response).to have_http_status(:success)
          expect(visible_ids_to_student_1).to include(@topic_visible_to_everyone.id)
          expect(visible_ids_to_student_1).to include(@topic.id)
        end

        it "is visible only to users who can access the assigned section" do
          assign_topic_to_section(@topic, @course_section)

          user_session(@student2)
          get "index", params: { course_id: @course.id }, format: :json
          parsed_json = json_parse(response.body)
          visible_ids_to_student_2 = parsed_json.pluck("id")
          expect(response).to have_http_status(:success)
          expect(visible_ids_to_student_2).to include(@topic_visible_to_everyone.id)
          expect(visible_ids_to_student_2).to include(@topic.id)

          user_session(@student1)
          get "index", params: { course_id: @course.id }, format: :json
          parsed_json = json_parse(response.body)
          visible_ids_to_student_1 = parsed_json.pluck("id")

          expect(response).to have_http_status(:success)
          expect(visible_ids_to_student_1).to include(@topic_visible_to_everyone.id)
          expect(visible_ids_to_student_1).not_to include(@topic.id)
        end

        it "is visible only to students in module override section" do
          @topic.only_visible_to_overrides = false
          @topic.save
          create_module_and_module_override(@topic, @student2)

          user_session(@student2)
          get "index", params: { course_id: @course.id }, format: :json
          parsed_json = json_parse(response.body)
          visible_ids_to_student_2 = parsed_json.pluck("id")

          expect(response).to have_http_status(:success)
          expect(visible_ids_to_student_2).to include(@topic_visible_to_everyone.id)
          expect(visible_ids_to_student_2).to include(@topic.id)

          user_session(@student1)
          get "index", params: { course_id: @course.id }, format: :json
          parsed_json = json_parse(response.body)
          visible_ids_to_student_1 = parsed_json.pluck("id")

          expect(response).to have_http_status(:success)
          expect(visible_ids_to_student_1).to include(@topic_visible_to_everyone.id)
          expect(visible_ids_to_student_1).not_to include(@topic.id)
        end

        it "shows observers their observed students topics" do
          assign_topic_to_section(@topic, @course_section)

          user_session(@observer)
          get "index", params: { course_id: @course.id }, format: :json
          parsed_json = json_parse(response.body)
          visible_ids_to_observer = parsed_json.pluck("id")

          expect(response).to have_http_status(:success)
          expect(visible_ids_to_observer).to include(@topic_visible_to_everyone.id)
          expect(visible_ids_to_observer).not_to include(@topic.id)

          @observer_enrollment.associated_user = @student2
          @observer_enrollment.save
          @observer.reload

          user_session(@observer)
          get "index", params: { course_id: @course.id }, format: :json
          parsed_json = json_parse(response.body)
          visible_ids_to_observer = parsed_json.pluck("id")

          expect(response).to have_http_status(:success)
          expect(visible_ids_to_observer).to include(@topic_visible_to_everyone.id)
          expect(visible_ids_to_observer).to include(@topic.id)
        end

        it "shows observers module overridden topics for their students" do
          @topic.only_visible_to_overrides = false
          @topic.save
          create_module_and_module_override(@topic, @student2)

          @observer_enrollment.associated_user = @student2
          @observer_enrollment.save
          @observer.reload

          user_session(@observer)
          get "index", params: { course_id: @course.id }, format: :json
          parsed_json = json_parse(response.body)
          visible_ids_to_observer = parsed_json.pluck("id")

          expect(response).to have_http_status(:success)
          expect(visible_ids_to_observer).to include(@topic_visible_to_everyone.id)
          expect(visible_ids_to_observer).to include(@topic.id)
        end

        it "shows observers topics of all students they are assigned to" do
          topic_for_student_3 = discussion_topic_model(user: @teacher, context: @course)
          topic_for_student_3.update!(only_visible_to_overrides: true)
          assign_topic_to_student(topic_for_student_3, @student3)

          assign_topic_to_student(@topic, @student2)

          observer = course_with_observer(course: @course, associated_user_id: @student2.id, active_all: true).user
          course_with_observer(course: @course, associated_user_id: @student3.id, active_all: true, user: observer).user

          user_session(observer)
          get "index", params: { course_id: @course.id }, format: :json
          parsed_json = json_parse(response.body)
          visible_ids_to_observer = parsed_json.pluck("id")

          expect(response).to have_http_status(:success)
          expect(visible_ids_to_observer).to include(@topic_visible_to_everyone.id)
          expect(visible_ids_to_observer).to include(@topic.id)
          expect(visible_ids_to_observer).to include(topic_for_student_3.id)
        end
      end

      def setup_course_and_users
        course_factory(active_all: true)
        @course_section = @course.course_sections.create

        @student1, @student2, @student3 = create_users(3, return_type: :record)
        [@student1, @student2, @student3].each { |student| @course.enroll_student(student, enrollment_state: "active") }
        student_in_section(@course.course_sections.first, user: @student1)
        student_in_section(@course.course_sections.second, user: @student2)

        course_with_observer(active_all: true, course: @course)
        @observer_enrollment = @enrollment
        @observer_enrollment.associated_user = @student1
        @observer_enrollment.save
        @observer.reload

        @teacher = teacher_in_course(course: @course, active_enrollment: true).user
      end

      def setup_discussion_topics
        @topic_visible_to_everyone = discussion_topic_model(user: @teacher, context: @course)
        @topic = discussion_topic_model(user: @teacher, context: @course)
        @topic.update!(only_visible_to_overrides: true)
      end

      def assign_topic_to_student(topic, student)
        override = topic.assignment_overrides.create!
        override.assignment_override_students.create!(user: student)
      end

      def assign_topic_to_section(topic, section)
        topic.assignment_overrides.create!(set: section)
      end

      def create_module_and_module_override(topic, student)
        context_module = @course.context_modules.create!(name: "module")
        context_module.add_item({ id: topic.id, type: "discussion_topic" })

        override = context_module.assignment_overrides.create!(set_type: "ADHOC")
        override.assignment_override_students.create!(user: student)
      end
    end

    context "assign to differentiation tags" do
      before :once do
        @course.account.enable_feature! :assign_to_differentiation_tags
        @course.account.tap do |a|
          a.settings[:allow_assign_to_differentiation_tags] = { value: true }
          a.save!
        end
      end

      it "adds differentiation tags information if account setting is on" do
        user_session(@teacher)
        get "index", params: { course_id: @course.id }
        expect(assigns[:js_env][:ALLOW_ASSIGN_TO_DIFFERENTIATION_TAGS]).to be true
        expect(assigns[:js_env][:CAN_MANAGE_DIFFERENTIATION_TAGS]).to be true
      end

      it "students cannot manage differentiation tags" do
        user_session(@student)
        get "index", params: { course_id: @course.id }
        expect(assigns[:js_env][:CAN_MANAGE_DIFFERENTIATION_TAGS]).to be false
      end
    end
  end

  describe "GET 'show'" do
    it "requires authorization" do
      course_topic
      get "show", params: { course_id: @course.id, id: @topic.id }
      assert_unauthorized
    end

    it "requires the course to be published for students" do
      course_topic
      @course.claim
      user_session(@student)
      get "show", params: { course_id: @course.id, id: @topic.id }
      assert_unauthorized
    end

    it "returns unauthorized if a user does not have visibilities" do
      user_session(@teacher)
      section1 = @course.course_sections.create!(name: "Section 1")
      section2 = @course.course_sections.create!(name: "Section 2")
      @course.enroll_teacher(@teacher, section: section1, allow_multiple_enrollments: true).accept!
      Enrollment.limit_privileges_to_course_section!(@course, @teacher, true)
      ann = @course.announcements.create!(message: "testing", is_section_specific: true, course_sections: [section2])
      ann.save!
      get :show, params: { course_id: @course.id, id: ann.id }
      get :edit, params: { course_id: @course.id, id: ann.id }
      expect(response).to have_http_status(:unauthorized)
    end

    it "redirects to index when student is trying to access unpublished discussion" do
      unpub_topic = @course.discussion_topics.build(title: "some topic", workflow_state: "unpublished")
      unpub_topic.save
      unpub_topic.reload
      user_session(@student)

      get("show", params: { course_id: @course.id, id: unpub_topic.id })
      expect(flash[:error]).to match(/You do not have access to the requested discussion./)
      expect(response).to be_redirect
      expect(response.location).to eq course_discussion_topics_url @course
    end

    context "js_env DISCUSSION_TOPIC PERMISSIONS CAN_SET_GROUP" do
      it "CAN_SET_GROUP is true when user is a teacher" do
        user_session(@teacher)
        regular_topic = @course.discussion_topics.create!(user: @teacher, title: "Greetings", message: "Hello, and good morning!")
        get "edit", params: { course_id: @course.id, id: regular_topic.id }
        expect(assigns[:js_env][:DISCUSSION_TOPIC][:PERMISSIONS][:CAN_SET_GROUP]).to be true
      end

      it "CAN_SET_GROUP is false when user is a student" do
        regular_topic = @course.discussion_topics.create!(user: @student, title: "Greetings", message: "Hello, and good morning!")
        user_session(@student)
        get("edit", params: { course_id: @course.id, id: regular_topic.id })
        expect(assigns[:js_env][:DISCUSSION_TOPIC][:PERMISSIONS][:CAN_SET_GROUP]).to be false
      end

      it "CAN_SET_GROUP is true for an account admin lacking manage_courses_admin" do
        regular_topic = @course.discussion_topics.create!(user: @teacher, title: "Greetings", message: "Hello, and good morning!")
        account_admin_user_with_role_changes(account: @account, role_changes: { manage_courses_admin: false, manage_groups_add: true })
        user_session(@admin)
        get("edit", params: { course_id: @course.id, id: regular_topic.id })
        expect(assigns[:js_env][:DISCUSSION_TOPIC][:PERMISSIONS][:CAN_SET_GROUP]).to be true
      end
    end

    context "js_env current_page is set correctly" do
      before do
        user_session(@student)
        course_topic
        41.times do |i|
          @topic.discussion_entries.create!(user: @teacher, message: (i + 1).to_s)
        end
        participant = @topic.participant(@student)
        participant.sort_order = DiscussionTopic::SortOrder::ASC
        participant.save!
      end

      it "top level entry are paginated" do
        get "show", params: { course_id: @course.id, id: @topic.id, entry_id: @topic.discussion_entries.last.id }
        expect(assigns[:js_env][:current_page]).to eq(2)
        get "show", params: { course_id: @course.id, id: @topic.id, entry_id: @topic.discussion_entries.first.id }
        expect(assigns[:js_env][:current_page]).to eq(0)
      end

      it "last and first entry of page are paginated" do
        get "show", params: { course_id: @course.id, id: @topic.id, entry_id: @topic.discussion_entries.first.id + 19 }
        expect(assigns[:js_env][:current_page]).to eq(0)
        get "show", params: { course_id: @course.id, id: @topic.id, entry_id: @topic.discussion_entries.first.id + 20 }
        expect(assigns[:js_env][:current_page]).to eq(1)
        get "show", params: { course_id: @course.id, id: @topic.id, entry_id: @topic.discussion_entries.first.id + 39 }
        expect(assigns[:js_env][:current_page]).to eq(1)
        get "show", params: { course_id: @course.id, id: @topic.id, entry_id: @topic.discussion_entries.first.id + 40 }
        expect(assigns[:js_env][:current_page]).to eq(2)
      end

      it "top level entry are paginated when desc" do
        participant = @topic.participant(@student)
        participant.sort_order = DiscussionTopic::SortOrder::DESC
        participant.save!
        get "show", params: { course_id: @course.id, id: @topic.id, entry_id: @topic.discussion_entries.last.id }
        expect(assigns[:js_env][:current_page]).to eq(0)
        get "show", params: { course_id: @course.id, id: @topic.id, entry_id: @topic.discussion_entries.first.id }
        expect(assigns[:js_env][:current_page]).to eq(2)
      end

      it "last and first entry of page are paginated when desc" do
        participant = @topic.participant(@student)
        participant.sort_order = DiscussionTopic::SortOrder::DESC
        participant.save!
        get "show", params: { course_id: @course.id, id: @topic.id, entry_id: @topic.discussion_entries.last.id - 19 }
        expect(assigns[:js_env][:current_page]).to eq(0)
        get "show", params: { course_id: @course.id, id: @topic.id, entry_id: @topic.discussion_entries.last.id - 20 }
        expect(assigns[:js_env][:current_page]).to eq(1)
        get "show", params: { course_id: @course.id, id: @topic.id, entry_id: @topic.discussion_entries.last.id - 39 }
        expect(assigns[:js_env][:current_page]).to eq(1)
        get "show", params: { course_id: @course.id, id: @topic.id, entry_id: @topic.discussion_entries.last.id - 40 }
        expect(assigns[:js_env][:current_page]).to eq(2)
      end

      it "child entry's parent page should be shown" do
        @topic.discussion_entries.create!(user: @teacher, message: "42", parent_id: @topic.discussion_entries.last.id)
        get "show", params: { course_id: @course.id, id: @topic.id, entry_id: @topic.discussion_entries.last.id }
        expect(assigns[:js_env][:current_page]).to eq(2)

        @topic.discussion_entries.create!(user: @teacher, message: "43", parent_id: @topic.discussion_entries.first.id)
        get "show", params: { course_id: @course.id, id: @topic.id, entry_id: @topic.discussion_entries.last.id }
        expect(assigns[:js_env][:current_page]).to eq(0)
      end
    end

    it "js_env requires user for apollo_caching" do
      Account.site_admin.enable_feature! :apollo_caching
      @course.update(is_public: true)

      @discussion = @course.discussion_topics.create!(user: @teacher, message: "hello")
      get "show", params: { course_id: @course.id, id: @discussion.id }
      expect(assigns[:js_env][:apollo_caching]).to be_nil
      user_session @student
      get "show", params: { course_id: @course.id, id: @discussion.id }
      expect(assigns[:js_env][:apollo_caching]).to be_truthy
    end

    it "js_env disable_keyboard_shortcuts should follow feature flag" do
      @student.enable_feature! :disable_keyboard_shortcuts
      user_session @student
      @discussion = @course.discussion_topics.create!(user: @teacher, message: "hello")
      get "show", params: { course_id: @course.id, id: @discussion.id }
      expect(assigns[:js_env][:disable_keyboard_shortcuts]).to be_truthy
    end

    it "logs an asset_user_access on show" do
      allow(@course).to receive(:feature_enabled?).and_call_original
      allow(@course).to receive(:feature_enabled?).with("react_discussions_post").and_return(true)
      user_session @student
      @discussion = @course.discussion_topics.create!(user: @teacher, message: "hello")
      get "show", params: { course_id: @course.id, id: @discussion.id }
      accessed_asset = assigns[:accessed_asset]
      expect(accessed_asset[:category]).to eq "topics"
    end

    it "js_bundles includes discussion_topics_post" do
      commons_hash = {
        base_url: "/testing-url",
        canvas_icon_class: "icon-commons",
        icon_url: "http://example.com/icon.png",
        id: "1",
        title: "Share to Commons"
      }
      allow(controller).to receive(:external_tools_display_hashes).and_return([commons_hash])
      user_session(@teacher)
      @discussion = @course.discussion_topics.create!(user: @teacher, title: "Greetings", message: "Hello, and good morning!")
      get "show", params: { course_id: @course.id, id: @discussion.id }
      expect(assigns[:js_bundles].first).to include(:discussion_topics_post)
      expect(assigns[:_crumbs]).to include(["Discussions", "/courses/#{@course.id}/discussion_topics", {}])
      expect(controller.js_env[:discussion_topic_menu_tools].first).to eq commons_hash
    end

    context "assign to differentiation tags" do
      before :once do
        @course.account.enable_feature! :assign_to_differentiation_tags
        @course.account.tap do |a|
          a.settings[:allow_assign_to_differentiation_tags] = { value: true }
          a.save!
        end
      end

      it "adds differentiation tags information if account setting is on" do
        user_session(@teacher)
        @discussion = @course.discussion_topics.create!(user: @teacher, message: "hello")
        get "show", params: { course_id: @course.id, id: @discussion.id }
        expect(assigns[:js_env][:ALLOW_ASSIGN_TO_DIFFERENTIATION_TAGS]).to be true
        expect(assigns[:js_env][:CAN_MANAGE_DIFFERENTIATION_TAGS]).to be true
      end

      it "CAN_MANAGE_DIFFERENTIAITON_TAGS is false if user cannot manage tags" do
        user_session(@student)
        @discussion = @course.discussion_topics.create!(user: @teacher, message: "hello")
        get "show", params: { course_id: @course.id, id: @discussion.id }
        expect(assigns[:js_env][:ALLOW_ASSIGN_TO_DIFFERENTIATION_TAGS]).to be true
        expect(assigns[:js_env][:CAN_MANAGE_DIFFERENTIATION_TAGS]).to be false
      end
    end

    it "does not work for announcements in a public course" do
      @course.update_attribute(:is_public, true)
      @announcement = @course.announcements.create!(
        title: "some announcement",
        message: "some message"
      )
      get "show", params: { course_id: @course.id, id: @announcement.id }
      expect(response).to_not be_successful
    end

    it "does not display announcements in private courses to users who aren't logged in" do
      announcement = @course.announcements.create!(title: "Test announcement", message: "Message")
      get("show", params: { course_id: @course.id, id: announcement.id })
      assert_unauthorized
    end

    context 'with the "react_discussions_post" FF enabled' do
      render_views
      subject { get "show", params: { course_id: course.id, id: discussion.id } }

      let!(:discussion) do
        course.discussion_topics.create!(
          user:,
          title: "Lego",
          message: "What upcoming set are you most excited for?"
        )
      end

      let(:course) { @course }
      let(:user) { @teacher }

      before do
        user_session(user)
      end

      it "sets user preference discussions_splitscreen_view" do
        subject

        expect(assigns[:js_env][:DISCUSSION][:preferences][:discussions_splitscreen_view]).to eq user.discussions_splitscreen_view?
      end

      it "sets ATTACHMENTS_FOLDER_ID" do
        subject

        expect(discussion).not_to be_for_assignment
        expect(assigns[:js_env][:DISCUSSION][:ATTACHMENTS_FOLDER_ID]).to eq Folder.unfiled_folder(user).id.to_s
      end

      context "no current user" do
        it "public course sets ATTACHMENTS_FOLDER_ID" do
          # in the controller 'can_read_and_visible' must be true, which is a complex flow to simulate
          allow_any_instance_of(DiscussionTopic).to receive(:grants_right?).and_return(true)
          allow_any_instance_of(DiscussionTopic).to receive(:visible_for?).and_return(true)

          course.update(is_public: true)
          discussion.assignment = course.assignments.build(submission_types: "discussion_topic", title: discussion.title)
          discussion.assignment.infer_times
          discussion.assignment.saved_by = :discussion_topic
          discussion.save
          remove_user_session

          subject
          expect(discussion).to be_for_assignment
          expect(assigns[:js_env][:DISCUSSION][:ATTACHMENTS_FOLDER_ID]).to eq Folder.unfiled_folder(discussion.course).id.to_s
        end
      end

      context "for_assignment" do
        it "sets ATTACHMENTS_FOLDER_ID" do
          discussion.assignment = course.assignments.build(submission_types: "discussion_topic", title: discussion.title)
          discussion.assignment.infer_times
          discussion.assignment.saved_by = :discussion_topic
          discussion.save

          subject
          expect(discussion).to be_for_assignment
          expect(assigns[:js_env][:DISCUSSION][:ATTACHMENTS_FOLDER_ID]).to eq Folder.unfiled_folder(user).id.to_s
        end
      end

      it "sets @page_title to Topic: @topic.title" do
        subject
        expect(assigns(:page_title)).to eq "Topic: #{discussion.title}"
      end

      it 'sets "rce_mentions_in_discussions" to true in the JS ENV' do
        subject
        expect(assigns.dig(:js_env, :rce_mentions_in_discussions)).to be true
      end

      context "topic is anonymous" do
        it 'sets "rce_mentions_in_discussions" to false in the JS ENV' do
          DiscussionTopic.where(id: discussion.id).update_all(anonymous_state: "full_anonymity")
          discussion.reload
          subject
          expect(assigns.dig(:js_env, :rce_mentions_in_discussions)).to be false
        end
      end

      context "summary" do
        it "teacher cannot summarize when the feature is disabled" do
          user_session(@teacher)
          get "show", params: { course_id: @course.id, id: discussion.id }
          expect(assigns.dig(:js_env, :user_can_summarize)).to be false
        end

        it "teacher can summarize when the feature is enabled" do
          Account.site_admin.enable_feature! :discussion_summary

          user_session(@teacher)
          get "show", params: { course_id: @course.id, id: discussion.id }
          expect(assigns.dig(:js_env, :user_can_summarize)).to be true
        end

        it "student cannot summarize when the feature is enabled" do
          Account.site_admin.enable_feature! :discussion_summary

          user_session(@student)
          get "show", params: { course_id: @course.id, id: discussion.id }
          expect(assigns.dig(:js_env, :user_can_summarize)).to be false
        end

        it "summary is not enabled on the topic" do
          user_session(@teacher)
          get "show", params: { course_id: @course.id, id: discussion.id }
          expect(assigns.dig(:js_env, :discussion_summary_enabled)).to be false
        end

        it "summary is enabled on the topic" do
          discussion.update!(summary_enabled: true)
          discussion.participant(@teacher).destroy
          user_session(@teacher)
          get "show", params: { course_id: @course.id, id: discussion.id }
          expect(assigns.dig(:js_env, :discussion_summary_enabled)).to be true
        end
      end

      context "insight" do
        it "teacher cannot access insights when the feature is disabled" do
          user_session(@teacher)
          get "show", params: { course_id: @course.id, id: discussion.id }
          expect(assigns.dig(:js_env, :user_can_access_insights)).to be false
        end

        it "teacher can access insights when the feature is enabled" do
          Account.site_admin.enable_feature! :discussion_insights

          user_session(@teacher)
          get "show", params: { course_id: @course.id, id: discussion.id }
          expect(assigns.dig(:js_env, :user_can_access_insights)).to be true
        end

        it "student cannot access insights when the feature is enabled" do
          Account.site_admin.enable_feature! :discussion_insights

          user_session(@student)
          get "show", params: { course_id: @course.id, id: discussion.id }
          expect(assigns.dig(:js_env, :user_can_access_insights)).to be false
        end
      end

      context "podcast_enabled" do
        it "adds Discussion Podcast Feed to header" do
          discussion.podcast_enabled = true
          discussion.save

          subject
          expect(response.body).to match(/.+enrollment.+\.rss/)
          expect(response.body).to include("Discussion Podcast Feed")
        end
      end

      it "adds Discussion Atom Feed to header" do
        subject
        expect(response.body).to match(/.+enrollment.+\.atom/)
        expect(response.body).to include("Discussion Atom Feed")
      end
    end

    context "section specific announcements" do
      before(:once) do
        course_with_teacher(active_course: true)
        @section = @course.course_sections.create!(name: "test section")

        @announcement = @course.announcements.create!(user: @teacher, message: "hello my favorite section!")
        @announcement.is_section_specific = true
        @announcement.course_sections = [@section]
        @announcement.save!

        @student1, @student2 = create_users(2, return_type: :record)
        @course.enroll_student(@student1, enrollment_state: "active")
        @course.enroll_student(@student2, enrollment_state: "active")
        student_in_section(@section, user: @student1)
      end

      it "is visible to students in specific section" do
        user_session(@student1)
        get "show", params: { course_id: @course.id, id: @announcement.id }
        expect(response).to be_successful
      end

      it "is not visible to students not in specific section announcements" do
        user_session(@student2)
        get("show", params: { course_id: @course.id, id: @announcement.id })
        expect(response).to be_redirect
        expect(response.location).to eq course_announcements_url @course
      end
    end

    context "section specific discussions" do
      before(:once) do
        course_with_teacher(active_course: true)
        @section = @course.course_sections.create!(name: "test section")

        @discussion = @course.discussion_topics.create!(user: @teacher, message: "hello my favorite section!")
        @discussion.is_section_specific = true
        @discussion.course_sections = [@section]
        @discussion.save!

        @student1, @student2 = create_users(2, return_type: :record)
        @course.enroll_student(@student1, enrollment_state: "active")
        @course.enroll_student(@student2, enrollment_state: "active")
        student_in_section(@section, user: @student1)
      end

      it "is visible to students in specific section" do
        user_session(@student1)
        get "show", params: { course_id: @course.id, id: @discussion.id }
        expect(response).to be_successful
      end

      it "is not visible to students not in specific section discussions" do
        user_session(@student2)
        get("show", params: { course_id: @course.id, id: @discussion.id })
        expect(response).to be_redirect
        expect(response.location).to eq course_discussion_topics_url @course
      end
    end

    context "ungraded discussions with module overrides" do
      before(:once) do
        course_with_teacher(active_course: true)

        @discussion = @course.discussion_topics.create!(user: @teacher, message: "hello my favorite section!")

        @student1, @student2 = create_users(2, return_type: :record)
        @course.enroll_student(@student1, enrollment_state: "active")
        @course.enroll_student(@student2, enrollment_state: "active")

        @context_module = @course.context_modules.create!(name: "module")
        @context_module.add_item({ id: @discussion.id, type: "discussion_topic" })

        override = @context_module.assignment_overrides.create!(set_type: "ADHOC")
        override.assignment_override_students.create!(user: @student1)
      end

      it "is visible to students with module override" do
        user_session(@student1)
        get "show", params: { course_id: @course.id, id: @discussion.id }
        expect(response).to be_successful
      end

      it "is not visible to students without module override" do
        user_session(@student2)
        get("show", params: { course_id: @course.id, id: @discussion.id })
        expect(response).to be_redirect
        expect(response.location).to eq course_discussion_topics_url @course
      end
    end

    context "discussion topic with assignment with overrides" do
      render_views

      before :once do
        course_topic(user: @teacher, with_assignment: true)
        @section = @course.course_sections.create!(name: "I <3 Discusions")
        @override = assignment_override_model(assignment: @topic.assignment,
                                              due_at: Time.zone.now,
                                              set: @section)
      end

      it "doesn't show the topic to unassigned students" do
        @topic.assignment.update_attribute(:only_visible_to_overrides, true)
        user_session(@student)
        get "show", params: { course_id: @course.id, id: @topic.id }
        expect(response).to be_redirect
        expect(response.location).to eq course_discussion_topics_url @course
      end
    end

    it "assigns variables" do
      user_session(@student)
      course_topic
      topic_entry
      @topic.reload
      expect(@topic.discussion_entries).not_to be_empty
      get "show", params: { course_id: @course.id, id: @topic.id }
      expect(response).to be_successful
      expect(assigns[:topic]).not_to be_nil
      expect(assigns[:topic]).to eql(@topic)
    end

    it "displays speedgrader when not for a large course" do
      user_session(@teacher)
      course_topic(user: @teacher, with_assignment: true)
      get "show", params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:SPEEDGRADER_URL_TEMPLATE]).to be_truthy
    end

    it "hides speedgrader when for a large course" do
      user_session(@teacher)
      course_topic(user: @teacher, with_assignment: true)
      allow_any_instance_of(Course).to receive(:large_roster?).and_return(true)
      get "show", params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:SPEEDGRADER_URL_TEMPLATE]).to be_nil
    end

    it "shows speedgrader when user can view all grades but not manage grades" do
      @course.account.role_overrides.create!(permission: "manage_grades", role: ta_role, enabled: false)
      user_session(@ta)
      course_topic(user: @teacher, with_assignment: true)
      get "show", params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:SPEEDGRADER_URL_TEMPLATE]).to be_truthy
    end

    it "shows speedgrader when user can manage grades but not view all grades" do
      @course.account.role_overrides.create!(permission: "view_all_grades", role: ta_role, enabled: false)
      user_session(@ta)
      course_topic(user: @teacher, with_assignment: true)
      get "show", params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:SPEEDGRADER_URL_TEMPLATE]).to be_truthy
    end

    it "does not show speedgrader when user can neither view all grades nor manage grades" do
      @course.account.role_overrides.create!(permission: "view_all_grades", role: ta_role, enabled: false)
      @course.account.role_overrides.create!(permission: "manage_grades", role: ta_role, enabled: false)
      user_session(@ta)
      course_topic(user: @teacher, with_assignment: true)
      get "show", params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:SPEEDGRADER_URL_TEMPLATE]).to be_nil
    end

    it "shows speedgrader when course concluded and user can read as admin" do
      user_session(@teacher)
      course_topic(user: @teacher, with_assignment: true)
      @course.soft_conclude!
      expect(@course.grants_right?(@teacher, :read_as_admin)).to be true
      get "show", params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:SPEEDGRADER_URL_TEMPLATE]).to be_truthy
    end

    it "setups speedgrader template for variable substitution" do
      user_session(@teacher)
      course_topic(user: @teacher, with_assignment: true)
      get "show", params: { course_id: @course.id, id: @topic.id }

      # this is essentially a unit test for ui/features/discussion_topic/backbone/models/Entry.js,
      # making sure that we get back the expected format for this url template
      template = assigns[:js_env][:SPEEDGRADER_URL_TEMPLATE]
      url = template.gsub("%3Astudent_id", "123")
      expect(url).to match "student_id=123"
    end

    it "marks as read when viewed" do
      user_session(@student)
      course_topic(skip_set_user: true)

      expect(@topic.read_state(@student)).to eq "unread"
      get "show", params: { course_id: @course.id, id: @topic.id }
      expect(@topic.reload.read_state(@student)).to eq "read"
    end

    it "marks as read when topic is in the future as teacher" do
      course_topic(skip_set_user: true)
      teacher2 = @course.shard.activate { user_factory }
      teacher2enrollment = @course.enroll_user(teacher2, "TeacherEnrollment")
      teacher2.save!
      teacher2enrollment.course = @course # set the reverse association
      teacher2enrollment.workflow_state = "active"
      teacher2enrollment.save!
      @course.reload
      @topic.available_from = 1.day.from_now
      @topic.save!
      @topic.reload
      expect(@topic.read_state(teacher2)).to eq "unread"
      user_session(teacher2)
      get "show", params: { course_id: @course.id, id: @topic.id }
      expect(@topic.reload.read_state(teacher2)).to eq "read"
    end

    it "does not mark as read if not visible" do
      user_session(@student)
      course_topic(skip_set_user: true)
      mod = @course.context_modules.create! name: "no soup for you", unlock_at: 1.year.from_now
      mod.add_item(type: "discussion_topic", id: @topic.id)
      mod.save!
      expect(@topic.read_state(@student)).to eq "unread"
      get "show", params: { course_id: @course.id, id: @topic.id }
      expect(@topic.reload.read_state(@student)).to eq "unread"
    end

    it "redirects while accessing locked announcements" do
      user_session(@student)
      course_topic(skip_set_user: true)
      @announcement = @course.announcements.create!(
        title: "some announcement",
        message: "some message",
        unlock_at: 1.week.ago,
        lock_at: 1.day.ago
      )
      get "show", params: { course_id: @course.id, id: @announcement.id }
      expect(response).to be_redirect
    end

    it "allows concluded teachers to see discussions" do
      user_session(@teacher)
      course_topic
      @enrollment.conclude
      get "show", params: { course_id: @course.id, id: @topic.id }
      expect(response).to be_successful
      get "index", params: { course_id: @course.id }
      expect(response).to be_successful
    end

    it "allows concluded students to see discussions" do
      user_session(@student)
      course_topic
      @enrollment.conclude
      get "show", params: { course_id: @course.id, id: @topic.id }
      expect(response).to be_successful
      get "index", params: { course_id: @course.id }
      expect(response).to be_successful
    end

    context "group discussions" do
      before(:once) do
        @group_category = @course.group_categories.create(name: "category 1")
        @group1 = @course.groups.create!(group_category: @group_category)
        @group2 = @course.groups.create!(group_category: @group_category)

        group_category2 = @course.group_categories.create(name: "category 2")
        @course.groups.create!(group_category: group_category2)

        course_topic(user: @teacher, with_assignment: true)
        @topic.group_category = @group_category
        @topic.save!

        @group1.add_user(@student)
      end

      it "provides sequence in js_env" do
        module1 = @course.context_modules.create!(name: "module1")
        module1.add_item(id: @topic.id, type: "discussion_topic")
        user_session(@teacher)

        get "show", params: { course_id: @course.id, id: @topic.id }
        expect(assigns[:js_env][:SEQUENCE]).to be_truthy
      end

      it "sets correct URL env vars" do
        outcome_with_rubric
        @rubric.associate_with(@topic.assignment, @course, purpose: "grading")
        @topic.assignment.peer_reviews = true
        user_session(@teacher)
        get "show", params: { course_id: @course.id, id: @topic.id }
        expect(assigns[:js_env][:EDIT_URL]).to eq "/courses/#{@course.id}/discussion_topics/#{@topic.id}/edit"
        expect(assigns[:js_env][:DISCUSSION][:GRADED_RUBRICS_URL]).to eq "/courses/#{@course.id}/assignments/#{@topic.assignment.id}/rubric"
        expect(assigns[:js_env][:DISCUSSION][:CONTEXT_RUBRICS_URL]).to eq "/courses/#{@course.id}/rubrics"
        expect(assigns[:js_env][:SPEEDGRADER_URL_TEMPLATE])
          .to eq "/courses/#{@course.id}/gradebook/speed_grader?assignment_id=#{@topic.assignment.id}&student_id=%3Astudent_id"
        expect(assigns[:js_env][:PEER_REVIEWS_URL]).to eq "/courses/#{@course.id}/assignments/#{@topic.assignment.id}/peer_reviews"
      end

      it "assigns groups from the topic's category" do
        user_session(@teacher)

        get "show", params: { course_id: @course.id, id: @topic.id }
        expect(assigns[:groups].size).to be(2)
      end

      it "only shows applicable groups if DA applies" do
        user_session(@teacher)

        asmt = @topic.assignment
        asmt.only_visible_to_overrides = true
        override = asmt.assignment_overrides.build
        override.set = @group2
        override.save!
        asmt.save!

        get "show", params: { course_id: @course.id, id: @topic.id }
        expect(response).to be_successful
        expect(assigns[:groups]).to eq([@group2])
      end

      it "redirects to group for student if DA applies to section" do
        user_session(@student)

        asmt = @topic.assignment
        asmt.only_visible_to_overrides = true
        override = asmt.assignment_overrides.build
        override.set = @course.default_section
        override.save!
        asmt.save!

        get "show", params: { course_id: @course.id, id: @topic.id }
        redirect_path = "/groups/#{@group1.id}/discussion_topics?root_discussion_topic_id=#{@topic.id}"
        expect(response).to redirect_to redirect_path
      end

      it "redirects to the student's group" do
        user_session(@student)

        get "show", params: { course_id: @course.id, id: @topic.id }
        redirect_path = "/groups/#{@group1.id}/discussion_topics?root_discussion_topic_id=#{@topic.id}"
        expect(response).to redirect_to redirect_path
      end

      it "redirects to the student's group even if students can view all groups" do
        @course.account.role_overrides.create!(
          role: student_role,
          permission: "view_group_pages",
          enabled: true
        )
        user_session(@student)

        get "show", params: { course_id: @course.id, id: @topic.id }
        redirect_path = "/groups/#{@group1.id}/discussion_topics?root_discussion_topic_id=#{@topic.id}"
        expect(response).to redirect_to redirect_path
      end

      it "redirects to groups with module_item_id, embed, display, session_timezome, and session_locale query params" do
        user_session(@student)
        get "show", params: {
          course_id: @course.id,
          id: @topic.id,
          embed: true,
          display: "borderless",
          session_timezone: "America/Los_Angeles",
          session_locale: "en",
          module_item_id: 789
        }

        expect(response).to be_redirect
        expect(response.location).to include "/groups/#{@group1.id}/discussion_topics?"
        expect(response.location).to include "module_item_id=789"
        expect(response.location).to include "embed=true"
        expect(response.location).to include "display=borderless"
        expect(response.location).to include "session_timezone=America%2FLos_Angeles"
        expect(response.location).to include "session_locale=en"
      end

      it "does not change the name of the child topic when navigating to it" do
        user_session(@student)

        child_topic = @topic.child_topic_for(@student)
        old_title = child_topic.title

        get "index", params: { group_id: @group1.id, root_discussion_topic_id: @topic.id }

        expect(@topic.child_topic_for(@student).title).to eq old_title
      end

      it "plumbs the module_item_id through group discussion redirect" do
        user_session(@student)

        get "show", params: { course_id: @course.id, id: @topic.id, module_item_id: 789 }
        expect(response).to be_redirect
        expect(response.location).to include "/groups/#{@group1.id}/discussion_topics?"
        expect(response.location).to include "module_item_id=789"
      end

      it "plumbs the module_item_id through child discussion redirect" do
        user_session(@student)

        get "index", params: { group_id: @group1.id, root_discussion_topic_id: @topic.id, module_item_id: 789 }
        expect(response).to be_redirect
        expect(response.location).to include "/groups/#{@group1.id}/discussion_topics/#{@topic.child_topic_for(@student).id}?"
        expect(response.location).to include "module_item_id=789"
      end

      it "excludes locked modules" do
        user_session(@student)
        course_topic(skip_set_user: true)
        mod = @course.context_modules.create! name: "no soup for you", unlock_at: 1.year.from_now
        mod.add_item(type: "discussion_topic", id: @topic.id)
        mod.save!
        expect(@topic.read_state(@student)).to eq "unread"
        get "index", params: { course_id: @course.id, exclude_context_module_locked_topics: true }, format: "json"
        expect(response.parsed_body.pluck("id")).to_not include @topic.id
      end
    end

    context "publishing" do
      render_views

      it "hides the publish icon for announcements" do
        user_session(@teacher)
        @context = @course
        @announcement = @course.announcements.create!(
          title: "some announcement",
          message: "some message"
        )
        get "show", params: { course_id: @course.id, id: @announcement.id }
        expect(response.body).not_to match "topic_publish_button"
      end
    end

    context "student context cards" do
      before(:once) do
        course_topic user: @teacher
      end

      it "is disabed for students" do
        user_session(@student)
        get :show, params: { course_id: @course.id, id: @topic.id }
        expect(assigns[:js_env][:STUDENT_CONTEXT_CARDS_ENABLED]).to be_falsey
      end

      it "is enabled for teachers" do
        user_session(@teacher)
        get :show, params: { course_id: @course.id, id: @topic.id }
        expect(assigns[:js_env][:STUDENT_CONTEXT_CARDS_ENABLED]).to be true
      end
    end

    it "successfully redirects no authorization for a public course" do
      @course.update(is_public: true)
      course_topic
      get "show", params: { course_id: @course.id, id: @topic.id }
      expect(response).to have_http_status :found
      expect(ErrorReport.last).to be_nil
    end

    context "attachment permissions" do
      before :once do
        @ann = @course.announcements.create!(message: "testing")
      end

      context "when allow_student_forum_attachments is false" do
        before :once do
          @course.allow_student_forum_attachments = false
          @course.save!
        end

        it "does not allow students to add attachments" do
          user_session(@student)
          get "show", params: { course_id: @course.id, id: @ann.id }
          expect(assigns[:js_env][:can_attach_entries]).to be_falsey
        end

        it "allows teachers to add attachments" do
          user_session(@teacher)
          get "show", params: { course_id: @course.id, id: @ann.id }
          expect(assigns[:js_env][:can_attach_entries]).to be_truthy
        end
      end

      context "when allow_student_forum_attachments is true" do
        before :once do
          @course.allow_student_forum_attachments = true
          @course.save!
        end

        it "allows students to add attachments" do
          user_session(@student)
          get "show", params: { course_id: @course.id, id: @ann.id }
          expect(assigns[:js_env][:can_attach_entries]).to be_truthy
        end

        it "allows teachers to add attachments" do
          user_session(@teacher)
          get "show", params: { course_id: @course.id, id: @ann.id }
          expect(assigns[:js_env][:can_attach_entries]).to be_truthy
        end
      end
    end
  end

  describe "GET 'new'" do
    it "maintains date and time when passed params" do
      user_session(@teacher)
      due_at = 1.day.from_now
      get "new", params: { course_id: @course.id, due_at: due_at.iso8601 }
      expect(assigns[:js_env][:DISCUSSION_TOPIC][:ATTRIBUTES][:assignment][:due_at]).to eq due_at.iso8601
    end

    it "js_env DUE_DATE_REQUIRED_FOR_ACCOUNT is true when AssignmentUtil.due_date_required_for_account? == true" do
      user_session(@teacher)
      allow(AssignmentUtil).to receive(:due_date_required_for_account?).and_return(true)
      get "new", params: { course_id: @course.id }
      expect(assigns[:js_env][:DUE_DATE_REQUIRED_FOR_ACCOUNT]).to be(true)
    end

    it "js_env DUE_DATE_REQUIRED_FOR_ACCOUNT is false when AssignmentUtil.due_date_required_for_account? == false" do
      user_session(@teacher)
      allow(AssignmentUtil).to receive(:due_date_required_for_account?).and_return(false)
      get "new", params: { course_id: @course.id }
      expect(assigns[:js_env][:DUE_DATE_REQUIRED_FOR_ACCOUNT]).to be(false)
    end

    it "js_env MAX_NAME_LENGTH_REQUIRED_FOR_ACCOUNT is true when AssignmentUtil.name_length_required_for_account? == true" do
      user_session(@teacher)
      allow(AssignmentUtil).to receive(:name_length_required_for_account?).and_return(true)
      get "new", params: { course_id: @course.id }
      expect(assigns[:js_env][:MAX_NAME_LENGTH_REQUIRED_FOR_ACCOUNT]).to be(true)
    end

    it "js_env MAX_NAME_LENGTH_REQUIRED_FOR_ACCOUNT is false when AssignmentUtil.name_length_required_for_account? == false" do
      user_session(@teacher)
      allow(AssignmentUtil).to receive(:name_length_required_for_account?).and_return(false)
      get "new", params: { course_id: @course.id }
      expect(assigns[:js_env][:MAX_NAME_LENGTH_REQUIRED_FOR_ACCOUNT]).to be(false)
    end

    it "js_env MAX_NAME_LENGTH is a 15 when AssignmentUtil.assignment_max_name_length returns 15" do
      user_session(@teacher)
      allow(AssignmentUtil).to receive(:assignment_max_name_length).and_return(15)
      get "new", params: { course_id: @course.id }
      expect(assigns[:js_env][:MAX_NAME_LENGTH]).to eq(15)
    end

    it "js_env SIS_NAME is Foo Bar when AssignmentUtil.post_to_sis_friendly_name is Foo Bar" do
      user_session(@teacher)
      allow(AssignmentUtil).to receive(:post_to_sis_friendly_name).and_return("Foo Bar")
      get "new", params: { course_id: @course.id }
      expect(assigns[:js_env][:SIS_NAME]).to eq("Foo Bar")
    end

    it "js_env allow_student_anonymous_discussion_topics defaults to false" do
      user_session(@teacher)
      get "new", params: { course_id: @course.id }
      expect(assigns[:js_env][:allow_student_anonymous_discussion_topics]).to be false
    end

    it "js_env allow_student_anonymous_discussion_topics is true when its only when course setting is true" do
      user_session(@teacher)
      @course.allow_student_anonymous_discussion_topics = true
      @course.save!
      get "new", params: { course_id: @course.id }
      expect(assigns[:js_env][:allow_student_anonymous_discussion_topics]).to be true
    end

    it "creates a default assignment group if none exist" do
      user_session(@teacher)
      get :new, params: { course_id: @course.id }
      expect(@course.assignment_groups.count).not_to eq 0
    end

    it "announcement" do
      user_session(@teacher)
      @course.group_weighting_scheme = "percent"
      @course.save!
      get :new, params: { course_id: @course.id, is_announcement: true }
      expect(assigns[:js_env][:CONTEXT_ID]).to eq(@course.id)
    end

    it "js_env DISCUSSION_TOPIC ATTRIBUTES course_published correctly for course context" do
      @course.workflow_state = "unpublished"
      @course.save!
      user_session(@teacher)
      get :new, params: { course_id: @course.id, is_announcement: true }
      expect(assigns[:js_env][:DISCUSSION_TOPIC][:ATTRIBUTES][:course_published]).to be_falsy
      @course.workflow_state = "available"
      @course.save!
      get :new, params: { course_id: @course.id, is_announcement: true }
      expect(assigns[:js_env][:DISCUSSION_TOPIC][:ATTRIBUTES][:course_published]).to be_truthy
    end

    it "js_env DISCUSSION_TOPIC ATTRIBUTES course_published correctly for group in course context" do
      @course.workflow_state = "unpublished"
      @course.save!
      @group_category = @course.group_categories.create(name: "gc")
      @group = @course.groups.create!(group_category: @group_category)
      user_session(@teacher)
      get :new, params: { group_id: @group.id, is_announcement: true }
      expect(assigns[:js_env][:DISCUSSION_TOPIC][:ATTRIBUTES][:course_published]).to be_falsy
      @course.workflow_state = "available"
      @course.save!
      get :new, params: { group_id: @group.id, is_announcement: true }
      expect(assigns[:js_env][:DISCUSSION_TOPIC][:ATTRIBUTES][:course_published]).to be_truthy
    end

    it "js_env DISCUSSION_TOPIC ATTRIBUTES course_published correctly for group in account context" do
      @group_category = Account.default.group_categories.create(name: "gc")
      @group = Account.default.groups.create!(group_category: @group_category)
      user_session(account_admin_user(account: Account.default))

      get :new, params: { group_id: @group.id, is_announcement: true }
      # will be truthy since there is no such thing as unpublished account context
      expect(assigns[:js_env][:DISCUSSION_TOPIC][:ATTRIBUTES][:course_published]).to be_truthy
    end

    it "js_bundles includes discussion_create when ff is on" do
      user_session(@teacher)
      @course.root_account.enable_feature!(:discussion_create)
      get :new, params: { course_id: @course.id }
      expect(assigns[:js_bundles].first).to include(:discussion_topic_edit_v2)
    end

    it "js_env DISCUSSION_CHECKPOINTS_ENABLED is set to true when creating a discussion and discussion checkpoints ff is on" do
      user_session(@teacher)
      @course.account.enable_feature!(:discussion_checkpoints)
      get :new, params: { course_id: @course.id }
      expect(assigns[:js_env][:DISCUSSION_CHECKPOINTS_ENABLED]).to be_truthy
    end

    it "js_env GROUP_CATEGORIES excludes non_collaborative and student_organized categories regardless of allow_assign_to_differentiation_tags setting state" do
      @course.account.settings[:allow_assign_to_differentiation_tags] = { value: true }
      @course.account.save!
      @course.account.reload

      user_session(@teacher)
      @course.group_categories.create!(name: "non_colaborative_category", non_collaborative: true)
      @course.group_categories.create!(name: "student_organized_category", role: "student_organized")
      regular_category = @course.group_categories.create!(name: "regular_category")

      get :new, params: { course_id: @course.id }
      expect(assigns[:js_env][:GROUP_CATEGORIES].pluck(:id)).to match_array [regular_category.id]

      @course.account.settings[:allow_assign_to_differentiation_tags] = { value: false }
      @course.account.save!
      @course.account.reload

      get :new, params: { course_id: @course.id }
      expect(assigns[:js_env][:GROUP_CATEGORIES].pluck(:id)).to match_array [regular_category.id]
    end

    it "js_env GROUP_CONTEXT_TYPE is set to nil when creating a discussion in course context" do
      user_session(@teacher)
      get :new, params: { course_id: @course.id }
      expect(assigns[:js_env][:GROUP_CONTEXT_TYPE]).to be_nil
    end

    it "js_env GROUP_CONTEXT_TYPE is set to 'Course' when creating a discussion in course group context" do
      user_session(@teacher)
      group = @course.groups.create!
      get :new, params: { group_id: group.id }
      expect(assigns[:js_env][:GROUP_CONTEXT_TYPE]).to eq("Course")
    end

    it "js_env GROUP_CONTEXT_TYPE is set to 'Account' when creating a discussion in account group context" do
      user_session(account_admin_user(account: Account.default))
      group = Account.default.groups.create!
      get :new, params: { group_id: group.id }
      expect(assigns[:js_env][:GROUP_CONTEXT_TYPE]).to eq("Account")
    end
  end

  describe "GET 'edit'" do
    before(:once) do
      course_topic
    end

    include_context "grading periods within controller" do
      let(:course) { @course }
      let(:teacher) { @teacher }
      let(:request_params) { [:edit, params: { course_id: course, id: @topic }] }
    end

    it "does not explode with mgp and group context" do
      group1 = Factories::GradingPeriodGroupHelper.new.create_for_account(@course.root_account)
      group1.enrollment_terms << @course.enrollment_term
      user_session(@teacher)
      group = group_model(context: @course)
      group_topic = group.discussion_topics.create!(title: "title")
      get(:edit, params: { group_id: group, id: group_topic })
      expect(response).to be_successful
      expect(assigns[:js_env]).to have_key(:active_grading_periods)
    end

    context "with sections" do
      subject { get :edit, params: { course_id: @course.id, id: ann.id } }

      before do
        user_session(@teacher)

        sections_to_enroll.each do |s|
          @course.enroll_teacher(@teacher, section: s, allow_multiple_enrollments: true).accept!
        end
      end

      let!(:sections_to_enroll) do
        [
          @course.course_sections.create!(name: "Z Section", start_at: 1.day.ago, end_at: 1.day.from_now, restrict_enrollments_to_section_dates: true),
          @course.course_sections.create!(name: "A Section"),
          @course.course_sections.create!(name: "K Section")
        ]
      end
      let!(:section_not_enrolled) { @course.course_sections.create!(name: "Section Not enrolled for teacher") }
      let(:ann) { @course.announcements.create!(message: "testing", is_section_specific: true, course_sections: sections_to_enroll) }

      it "orders the sections alphabetically" do
        subject
        expect(assigns[:js_env][:SECTION_LIST].length).to eq(5)
        expect(assigns[:js_env][:SECTION_LIST][0][:name]).to eq(sections_to_enroll[1][:name])
        expect(assigns[:js_env][:SECTION_LIST][1][:name]).to eq(sections_to_enroll[2][:name])
        # default course is returned at position 2
        expect(assigns[:js_env][:SECTION_LIST][4][:name]).to eq(sections_to_enroll[0][:name])
      end

      it "selects correct attributes for sections" do
        subject
        section = assigns[:js_env][:SECTION_LIST][4]
        expect(section[:id]).to eq(sections_to_enroll[0].id)
        expect(section[:name]).to eq(sections_to_enroll[0].name)
        expect(section[:start_at]).to eq(sections_to_enroll[0].start_at)
        expect(section[:end_at]).to eq(sections_to_enroll[0].end_at)
        expect(section[:override_course_and_term_dates]).to eq(sections_to_enroll[0].restrict_enrollments_to_section_dates)
      end

      it "selects correct attributes for selected_section_list" do
        subject
        expect(assigns[:js_env][:SELECTED_SECTION_LIST].length).to eq(sections_to_enroll.length)
        selected_section_sample = assigns[:js_env][:SELECTED_SECTION_LIST].find { |s| s[:id] == sections_to_enroll[0].id }
        expect(selected_section_sample[:id]).to eq(sections_to_enroll[0].id)
        expect(selected_section_sample[:name]).to eq(sections_to_enroll[0].name)
      end

      context "with limited priviliges user" do
        before { Enrollment.limit_privileges_to_course_section!(@course, @teacher, true) }

        it "filters sections to those the user is enrolled in" do
          subject
          # 2 because there is a default course created in the course_with_teacher factory
          expect(assigns[:js_env][:SECTION_LIST].length).to eq(4)
          expect(assigns[:js_env][:SECTION_LIST].pluck(:name)).not_to include(section_not_enrolled.name)
        end
      end

      context "with NOT limited priviliges user" do
        before { Enrollment.limit_privileges_to_course_section!(@course, @teacher, false) }

        it "returns all the sections to the course" do
          subject
          # 3 because there is a default course created in the course_with_teacher factory
          expect(assigns[:js_env][:SECTION_LIST].length).to eq(5)
          expect(assigns[:js_env][:SECTION_LIST].pluck(:name)).to include(section_not_enrolled.name)
        end
      end

      context "when context is a group" do
        subject { get :edit, params: { group_id: group, id: group_topic } }

        before do
          group1 = Factories::GradingPeriodGroupHelper.new.create_for_account(@course.root_account)
          group1.enrollment_terms << @course.enrollment_term
          user_session(@teacher)
        end

        let(:group) { group_model(context: @course) }
        let(:group_topic) { group.discussion_topics.create!(title: "title") }

        it "returns an empty sections list" do
          subject
          expect(response).to be_successful
          expect(assigns[:js_env][:SECTION_LIST]).to be_empty
          expect(assigns[:js_env][:SELECTED_SECTION_LIST]).to be_nil
        end
      end
    end

    it "returns unauthorized for a user that does not have visibilites to view thiss" do
      user_session(@teacher)
      section1 = @course.course_sections.create!(name: "Section 1")
      section2 = @course.course_sections.create!(name: "Section 2")
      @course.enroll_teacher(@teacher, section: section1, allow_multiple_enrollments: true).accept!
      Enrollment.limit_privileges_to_course_section!(@course, @teacher, true)
      ann = @course.announcements.create!(message: "testing", is_section_specific: true, course_sections: [section2])
      ann.save!
      get :edit, params: { course_id: @course.id, id: ann.id }
      assert_unauthorized
    end

    it "js_env GROUP_CATEGORIES excludes non_collaborative and student_organized categories regardless of allow_assign_to_differentiation_tags setting state" do
      @course.account.settings[:allow_assign_to_differentiation_tags] = { value: true }
      @course.account.save!
      @course.account.reload

      user_session(@teacher)
      @course.group_categories.create!(name: "non_colaborative_category", non_collaborative: true)
      @course.group_categories.create!(name: "student_organized_category", role: "student_organized")
      regular_category = @course.group_categories.create!(name: "regular_category")

      get :edit, params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:GROUP_CATEGORIES].pluck(:id)).to match_array [regular_category.id]

      @course.account.settings[:allow_assign_to_differentiation_tags] = { value: false }
      @course.account.save!
      @course.account.reload

      get :edit, params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:GROUP_CATEGORIES].pluck(:id)).to match_array [regular_category.id]
    end

    it "js_env DUE_DATE_REQUIRED_FOR_ACCOUNT is true when AssignmentUtil.due_date_required_for_account? == true" do
      user_session(@teacher)
      allow(AssignmentUtil).to receive(:due_date_required_for_account?).and_return(true)
      get :edit, params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:DUE_DATE_REQUIRED_FOR_ACCOUNT]).to be(true)
    end

    it "js_env DUE_DATE_REQUIRED_FOR_ACCOUNT is false when AssignmentUtil.due_date_required_for_account? == false" do
      user_session(@teacher)
      allow(AssignmentUtil).to receive(:due_date_required_for_account?).and_return(false)
      get :edit, params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:DUE_DATE_REQUIRED_FOR_ACCOUNT]).to be(false)
    end

    it "js_env MAX_NAME_LENGTH_REQUIRED_FOR_ACCOUNT is true when AssignmentUtil.name_length_required_for_account? == true" do
      user_session(@teacher)
      allow(AssignmentUtil).to receive(:name_length_required_for_account?).and_return(true)
      get :edit, params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:MAX_NAME_LENGTH_REQUIRED_FOR_ACCOUNT]).to be(true)
    end

    it "js_env MAX_NAME_LENGTH_REQUIRED_FOR_ACCOUNT is false when AssignmentUtil.name_length_required_for_account? == false" do
      user_session(@teacher)
      allow(AssignmentUtil).to receive(:name_length_required_for_account?).and_return(false)
      get :edit, params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:MAX_NAME_LENGTH_REQUIRED_FOR_ACCOUNT]).to be(false)
    end

    it "js_env MAX_NAME_LENGTH is a 15 when AssignmentUtil.assignment_max_name_length returns 15" do
      user_session(@teacher)
      allow(AssignmentUtil).to receive(:assignment_max_name_length).and_return(15)
      get :edit, params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:MAX_NAME_LENGTH]).to eq(15)
    end

    it "js_env SIS_NAME is Foo Bar when AssignmentUtil.post_to_sis_friendly_name is Foo Bar" do
      user_session(@teacher)
      allow(AssignmentUtil).to receive(:post_to_sis_friendly_name).and_return("Foo Bar")
      get :edit, params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:SIS_NAME]).to eq("Foo Bar")
    end

    it "js_env allow_student_anonymous_discussion_topics defaults to false" do
      user_session(@teacher)
      get :edit, params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:allow_student_anonymous_discussion_topics]).to be false
    end

    it "js_env allow_student_anonymous_discussion_topics is true when its only when course setting is true" do
      user_session(@teacher)
      @course.allow_student_anonymous_discussion_topics = true
      @course.save!
      get :edit, params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:allow_student_anonymous_discussion_topics]).to be true
    end

    it "js_env DISCUSSION_CHECKPOINTS_ENABLED is set to true when editing a discussion and discussion checkpoints ff is on" do
      user_session(@teacher)
      @course.account.enable_feature!(:discussion_checkpoints)
      get :edit, params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:DISCUSSION_CHECKPOINTS_ENABLED]).to be_truthy
    end

    it "js_env RESTRICT_QUANTITATIVE_DATA is set to true if enabled in course" do
      user_session(@teacher)
      @course.restrict_quantitative_data = true
      @course.save!
      get :edit, params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:RESTRICT_QUANTITATIVE_DATA]).to be_truthy
    end

    it "js_env RESTRICT_QUANTITATIVE_DATA is set to false if disabled in course" do
      user_session(@teacher)
      @course.restrict_quantitative_data = false
      @course.save!
      get :edit, params: { course_id: @course.id, id: @topic.id }
      expect(assigns[:js_env][:RESTRICT_QUANTITATIVE_DATA]).to be_falsy
    end

    it "js_env GROUP_CONTEXT_TYPE is set to nil when editing a discussion in course context" do
      user_session(@teacher)
      topic = @course.discussion_topics.create!(title: "course topic", message: "Hello", user: @student)
      get :edit, params: { course_id: @course.id, id: topic.id }
      expect(assigns[:js_env][:GROUP_CONTEXT_TYPE]).to be_nil
    end

    it "js_env GROUP_CONTEXT_TYPE is set to 'Course' when editing a discussion in course group context" do
      user_session(@teacher)
      group = @course.groups.create!
      topic = group.discussion_topics.create!(title: "course group topic", message: "Hello", user: @student)
      get :edit, params: { group_id: group.id, id: topic.id }
      expect(assigns[:js_env][:GROUP_CONTEXT_TYPE]).to eq("Course")
    end

    it "js_env GROUP_CONTEXT_TYPE is set to 'Account' when editing a discussion in account group context" do
      user_session(account_admin_user(account: Account.default))
      group = Account.default.groups.create!
      topic = group.discussion_topics.create!(title: "account group topic", message: "Hello", user: @student)
      get :edit, params: { group_id: group.id, id: topic.id }
      expect(assigns[:js_env][:GROUP_CONTEXT_TYPE]).to eq("Account")
    end

    context "assign to differentiation tags" do
      before :once do
        @course.account.enable_feature! :assign_to_differentiation_tags
        @course.account.tap do |a|
          a.settings[:allow_assign_to_differentiation_tags] = { value: true }
          a.save!
        end
      end

      it "adds differentiation tags information if account setting is on" do
        user_session(@teacher)
        get "edit", params: { course_id: @course.id, id: @topic.id }
        expect(assigns[:js_env][:ALLOW_ASSIGN_TO_DIFFERENTIATION_TAGS]).to be true
        expect(assigns[:js_env][:CAN_MANAGE_DIFFERENTIATION_TAGS]).to be true
      end
    end

    context "conditional-release" do
      before do
        user_session(@teacher)
      end

      it "includes environment variables if enabled" do
        allow(ConditionalRelease::Service).to receive_messages(enabled_in_context?: true, env_for: { dummy: "value" })
        get :edit, params: { course_id: @course.id, id: @topic.id }
        expect(response).to be_successful
        expect(controller.js_env[:dummy]).to eq "value"
      end

      it "does not include environment variables when disabled" do
        allow(ConditionalRelease::Service).to receive_messages(enabled_in_context?: false, env_for: { dummy: "value" })
        get :edit, params: { course_id: @course.id, id: @topic.id }
        expect(response).to be_successful
        expect(controller.js_env).not_to have_key :dummy
      end
    end

    context "usage rights - teacher" do
      before { user_session(@teacher) }

      before :once do
        attachment_model
        @topic_with_file = @course.discussion_topics.create!(title: "some topic", attachment: @attachment)
      end

      shared_examples_for "no usage rights returned" do
        it "does not return usage rights on discussion topic attachment" do
          get :edit, params: { course_id: @course.id, id: @topic_with_file.id }
          expect(assigns[:js_env][:DISCUSSION_TOPIC][:ATTRIBUTES]["attachments"][0]).not_to have_key("usage_rights")
        end
      end

      shared_examples_for "usage rights returned" do
        it "returns usage rights on discussion topic attachment" do
          get :edit, params: { course_id: @course.id, id: @topic_with_file.id }
          expect(assigns[:js_env][:DISCUSSION_TOPIC][:ATTRIBUTES]["attachments"][0]).to have_key("usage_rights")
        end
      end

      context "enabled on course" do
        before { @course.update!(usage_rights_required: true) }

        include_examples "usage rights returned"
      end

      context "disabled on course" do
        before { @course.update!(usage_rights_required: false) }

        include_examples "no usage rights returned"
      end
    end
  end

  describe "GET 'insights'" do
    before(:once) do
      course_with_teacher(active_all: true)
      @topic = @course.discussion_topics.create!(title: "Test Topic")
    end

    context "when the feature flag is enabled" do
      before do
        @course.root_account.enable_feature!(:discussion_insights)
      end

      it "renders the insights page" do
        user_session(@teacher)
        get :insights, params: { course_id: @course.id, id: @topic.id }
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "ignore malicious message on create or update" do
    before(:once) do
      @topic = DiscussionTopic.create!(context: @course, title: "Test Topic", message: "Original Message")
    end

    it "sanitizes HTML content in the message field during create" do
      user_session(@teacher)
      malicious_message = "<script>alert('XSS')</script><b>Bold Text</b>"
      sanitized_message = "<b>Bold Text</b>"

      post "create", params: { course_id: @course.id, title: "Test Topic", message: malicious_message }, format: :json

      expect(response).to have_http_status(:ok)
      topic = DiscussionTopic.last
      expect(topic.message).to eq sanitized_message
    end

    it "removes unsanitized HTML during create" do
      user_session(@teacher)
      malicious_message = "<img src='x' onerror='alert(1)'>"
      sanitized_message = "<img src=\"x\">"

      post "create", params: { course_id: @course.id, title: "Test Topic", message: malicious_message }, format: :json

      expect(response).to have_http_status(:ok)
      topic = DiscussionTopic.last
      expect(topic.message).to eq sanitized_message
    end

    it "sanitizes HTML content in the message field during update" do
      user_session(@teacher)
      malicious_message = "<script>alert('XSS')</script><b>Bold Text</b>"
      sanitized_message = "<b>Bold Text</b>"

      put "update", params: { course_id: @course.id, topic_id: @topic.id, message: malicious_message }, format: :json

      expect(response).to have_http_status(:ok)
      expect(@topic.reload.message).to eq sanitized_message
    end

    it "removes unsanitized HTML during update" do
      user_session(@teacher)
      malicious_message = "<img src='x' onerror='alert(1)'>"
      sanitized_message = "<img src=\"x\">"

      put "update", params: { course_id: @course.id, topic_id: @topic.id, message: malicious_message }, format: :json

      expect(response).to have_http_status(:ok)
      expect(@topic.reload.message).to eq sanitized_message
    end
  end

  context "student planner" do
    before do
      course_topic
    end

    it "creates a topic with a todo date" do
      user_session(@teacher)
      todo_date = 1.day.from_now.in_time_zone("America/New_York")
      post "create", params: { course_id: @course.id, todo_date:, title: "Discussion 1" }, format: "json"
      expect(response.parsed_body["todo_date"]).to eq todo_date.utc.iso8601
    end

    it "updates a topic with a todo date" do
      user_session(@teacher)
      todo_date = 1.day.from_now.in_time_zone("America/New_York")
      put "update", params: { course_id: @course.id, topic_id: @topic.id, todo_date: todo_date.iso8601(6) }, format: "json"
      expect(@topic.reload.todo_date).to eq todo_date
    end

    it "removes a todo date from a topic" do
      user_session(@teacher)
      @topic.update(todo_date: 1.day.from_now.in_time_zone("America/New_York"))
      put "update", params: { course_id: @course.id, topic_id: @topic.id, todo_date: nil }, format: "json"
      expect(@topic.reload.todo_date).to be_nil
    end

    it "does not allow a student to update the to-do date" do
      user_session(@student)
      put "update", params: { course_id: @course.id, topic_id: @topic.id, todo_date: 1.day.from_now }, format: "json"
      expect(@topic.reload.todo_date).to be_nil
    end

    it "does not allow a todo date on a graded topic" do
      user_session(@teacher)
      assign = @course.assignments.create!(title: "Graded Topic 1", submission_types: "discussion_topic")
      topic = assign.discussion_topic
      put "update", params: { course_id: @course.id, topic_id: topic.id, todo_date: 1.day.from_now }, format: "json"
      expect(response).to have_http_status :bad_request
    end

    it "does not allow changing a topic to graded and adding a todo date" do
      user_session(@teacher)
      put "update",
          params: { course_id: @course.id,
                    topic_id: @topic.id,
                    todo_date: 1.day.from_now,
                    assignment: { submission_types: ["discussion_topic"], name: "Graded Topic 1" } },
          format: "json"
      expect(response).to have_http_status :bad_request
    end

    it "allows a todo date when changing a topic from graded to ungraded" do
      user_session(@teacher)
      todo_date = 1.day.from_now
      assign = @course.assignments.create!(title: "Graded Topic 1", submission_types: "discussion_topic")
      topic = assign.discussion_topic
      put "update",
          params: { course_id: @course.id,
                    topic_id: topic.id,
                    todo_date: todo_date.iso8601(6),
                    assignment: { set_assignment: false, name: "Graded Topic 1" } },
          format: "json"
      expect(response).to have_http_status :ok
      expect(topic.reload.assignment).to be_nil
      expect(topic.todo_date).to eq todo_date
    end

    it "removes an existing todo date when changing a topic from ungraded to graded" do
      user_session(@teacher)
      @topic.update(todo_date: 1.day.from_now)
      put "update",
          params: { course_id: @course.id,
                    topic_id: @topic.id,
                    assignment: { submission_types: ["discussion_topic"], name: "Graded Topic 1" } },
          format: "json"
      expect(response).to have_http_status :ok
      expect(@topic.reload.assignment).to be_truthy
      expect(@topic.todo_date).to be_nil
    end
  end

  describe "GET 'public_feed.atom'" do
    before(:once) do
      course_topic
    end

    it "requires authorization" do
      get "public_feed", params: { feed_code: @course.feed_code + "x" }, format: "atom"
      expect(assigns[:problem]).to eql("The verification code is invalid.")
    end

    it "includes absolute path for rel='self' link" do
      get "public_feed", params: { feed_code: @course.feed_code }, format: "atom"
      feed = Feedjira.parse(response.body)
      expect(feed).not_to be_nil
      expect(feed.feed_url).to match(%r{http://})
    end

    it "does not include entries in an anonymous feed" do
      get "public_feed", params: { feed_code: @course.feed_code }, format: "atom"
      feed = Feedjira.parse(response.body)
      expect(feed).not_to be_nil
      expect(feed.entries).to be_empty
    end

    it "includes an author for each entry with an enrollment feed" do
      get "public_feed", params: { feed_code: @course.teacher_enrollments.first.feed_code }, format: "atom"
      feed = Feedjira.parse(response.body)
      expect(feed).not_to be_nil
      expect(feed.entries).not_to be_empty
      expect(feed.entries.all? { |e| e.author.present? }).to be_truthy
    end
  end

  describe "POST create:" do
    before(:once) do
      Setting.set("enable_page_views", "db")
    end

    before do
      allow(controller).to receive_messages(form_authenticity_token: "abc", form_authenticity_param: "abc")
    end

    describe "create_announcements_unlocked preference" do
      before do
        @teacher.create_announcements_unlocked(false)
        user_session(@teacher)
      end

      it "is updated when creating new announcements" do
        post_params = topic_params(@course, { is_announcement: true, locked: false })
        post("create", params: post_params, format: :json)
        @teacher.reload
        expect(@teacher.create_announcements_unlocked?).to be_truthy
      end

      it "is not updated when creating new discussions" do
        post_params = topic_params(@course, { is_announcement: false, locked: false })
        post("create", params: post_params, format: :json)
        @teacher.reload
        expect(@teacher.create_announcements_unlocked?).to be_falsey
      end
    end

    describe "handle locked parameter" do
      before do
        user_session(@teacher)
      end

      it "removes discussion_type and require_initial_post when is_announcement is true and lock_comment is true" do
        post_params = topic_params(@course, { is_announcement: true, lock_comment: true, discussion_type: "threaded", require_initial_post: true })
        post "create", params: post_params, format: :json
        topic = assigns[:topic]

        expect(topic.is_announcement).to be_truthy
        expect(topic.locked).to be_truthy
        expect(topic.discussion_type).to eq "threaded"
        expect(topic.require_initial_post).to be_falsey
      end

      it "does not remove discussion_type and require_initial_post when is_announcement is true and lock_comment is false" do
        post_params = topic_params(@course, { is_announcement: true, lock_comment: false, discussion_type: "threaded", require_initial_post: true })
        post "create", params: post_params, format: :json
        topic = assigns[:topic]

        expect(topic.is_announcement).to be_truthy
        expect(topic.locked).to be_falsey
        expect(topic.discussion_type).to eq "threaded"
        expect(topic.require_initial_post).to be_truthy
      end
    end

    describe "the new topic" do
      let(:topic) { assigns[:topic] }

      before do
        user_session(@student)
        post "create", params: topic_params(@course), format: :json
      end

      specify { expect(topic).to be_a DiscussionTopic }
      specify { expect(topic.user).to eq @user }
      specify { expect(topic.delayed_post_at).to be_nil }
      specify { expect(topic.lock_at).to be_nil }
      specify { expect(topic.workflow_state).to eq "active" }
      specify { expect(topic.id).not_to be_nil }
      specify { expect(topic.title).to eq "Topic Title" }
      specify { expect(topic.is_announcement).to be_falsey }
      specify { expect(topic.discussion_type).to eq "side_comment" }
      specify { expect(topic.message).to eq "Message" }
      specify { expect(topic.threaded).to be_falsey }
    end

    # TODO: fix this terribleness
    describe "section specific discussions" do
      before do
        user_session(@teacher)
        @section1 = @course.course_sections.create!(name: "Section 1")
        @section2 = @course.course_sections.create!(name: "Section 2")
        @section3 = @course.course_sections.create!(name: "Section 3")
        @section4 = @course.course_sections.create!(name: "Section 4")
        @course.enroll_teacher(@teacher, section: @section1, allow_multiple_enrollments: true).accept!
        @course.enroll_teacher(@teacher, section: @section2, allow_multiple_enrollments: true).accept!
        Enrollment.limit_privileges_to_course_section!(@course, @teacher, true)
      end

      it "creates an announcement with sections" do
        post "create",
             params: topic_params(@course, { is_announcement: true, specific_sections: @section1.id.to_s }),
             format: :json
        expect(response).to be_successful
        expect(DiscussionTopic.last.course_sections.first).to eq @section1
        expect(DiscussionTopicSectionVisibility.count).to eq 1
      end

      it "section-specific-teachers can create course-wide discussions" do
        old_count = DiscussionTopic.count
        post "create",
             params: topic_params(@course, { is_announcement: true }),
             format: :json
        expect(response).to be_successful
        expect(DiscussionTopic.count).to eq old_count + 1
        expect(DiscussionTopic.last.is_section_specific).to be_falsey
      end

      it "section-specfic-teachers cannot create wrong-section discussions" do
        old_count = DiscussionTopic.count
        post "create",
             params: topic_params(@course, { is_announcement: true, specific_sections: @section3.id.to_s }),
             format: :json
        expect(response).to have_http_status :bad_request
        expect(DiscussionTopic.count).to eq old_count
      end

      it "admins can see section-specific discussions" do
        admin = account_admin_user(account: @course.root_account, role: admin_role, active_user: true)
        user_session(admin)
        topic = @course.discussion_topics.create!
        topic.is_section_specific = true
        topic.course_sections << @section1
        topic.save!
        get "index", params: { course_id: @course.id }, format: :json
        expect(response).to be_successful
        expect(assigns[:topics].length).to eq(1)
      end

      it "admins can create section-specific discussions" do
        admin = account_admin_user(account: @course.root_account, role: admin_role, active_user: true)
        user_session(admin)
        post "create",
             params: topic_params(@course, { is_announcement: true, specific_sections: @section1.id.to_s }),
             format: :json
        expect(response).to be_successful
        expect(DiscussionTopic.last.course_sections.first).to eq @section1
      end

      it "creates a discussion with sections" do
        post "create",
             params: topic_params(@course, { specific_sections: @section1.id.to_s }),
             format: :json
        expect(response).to be_successful
        expect(DiscussionTopic.last.course_sections.first).to eq @section1
        expect(DiscussionTopicSectionVisibility.count).to eq 1
      end

      it "does not allow creation of group discussions that are section specific" do
        @group_category = @course.group_categories.create(name: "gc")
        @group = @course.groups.create!(group_category: @group_category)
        post "create",
             params: group_topic_params(@group, { specific_sections: @section1.id.to_s }),
             format: :json
        expect(response).to have_http_status :bad_request
        expect(DiscussionTopic.count).to eq 0
        expect(DiscussionTopicSectionVisibility.count).to eq 0
      end

      # Note that this is different then group discussions. This is the
      # "This is a Group Discussion" checkbox on a course discussion edit page,
      # whereas that one is creating a discussion in a group page.
      it "does not allow creation of discussions with groups that are section specific" do
        @group_category = @course.group_categories.create(name: "gc")
        @group = @course.groups.create!(group_category: @group_category)
        param_overrides = {
          specific_sections: "#{@section1.id},#{@section2.id}",
          group_category_id: @group_category.id,
        }
        post("create", params: topic_params(@course, param_overrides), format: :json)
        expect(response).to have_http_status :bad_request
        expect(DiscussionTopic.count).to eq 0
        expect(DiscussionTopicSectionVisibility.count).to eq 0
      end

      it "does not allow creation of graded discussions that are section specific" do
        obj_params = topic_params(@course, { specific_sections: @section1.id.to_s })
                     .merge(assignment_params(@course))
        expect(DiscussionTopic.count).to eq 0
        post("create", params: obj_params, format: :json)
        expect(response).to have_http_status :unprocessable_entity
        expect(DiscussionTopic.count).to eq 0
        expect(DiscussionTopicSectionVisibility.count).to eq 0
      end

      it "does not allow creation of disuccions to sections that are not visible to the user" do
        # This teacher does not have permissino for section 3 and 4
        sections = [@section1.id, @section2.id, @section3.id, @section4.id].join(",")
        post "create", params: topic_params(@course, { specific_sections: sections }), format: :json
        expect(response).to have_http_status :bad_request
        expect(DiscussionTopic.count).to eq 0
        expect(DiscussionTopicSectionVisibility.count).to eq 0
      end
    end

    describe "discussion anonymity" do
      it "allows full_anonymity" do
        user_session @teacher
        post "create", params: topic_params(@course, { anonymous_state: "full_anonymity" }), format: :json
        expect(response).to be_successful
        expect(DiscussionTopic.last.anonymous_state).to eq "full_anonymity"
        expect(DiscussionTopic.last).to be_anonymous
      end

      it "returns an error for creating anonymous discussions in a Group" do
        group_category = @course.group_categories.create(name: "gc")
        group = @course.groups.create!(group_category:)
        user_session @teacher
        post "create", params: group_topic_params(group, { anonymous_state: "full_anonymity" }), format: :json
        expect(response).to have_http_status :bad_request
        expect(response.parsed_body["errors"]).to include({ "anonymous_state" => "Group discussions cannot be anonymous." })
      end

      it "returns an error for creating anonymous discussions assigned to a Group Category in a Course" do
        group_category = @course.group_categories.create(name: "gc")
        user_session @teacher
        post "create", params: topic_params(@course, { anonymous_state: "full_anonymity", group_category_id: group_category.id }), format: :json
        expect(response).to have_http_status :bad_request
        expect(response.parsed_body["errors"]).to include({ "anonymous_state" => "Group discussions cannot be anonymous." })
      end

      it "returns an error for creating a graded anonymous discussion" do
        obj_params = topic_params(@course, { anonymous_state: "full_anonymity" }).merge(assignment_params(@course))
        user_session(@teacher)
        post "create", params: obj_params, format: :json
        expect(response).to have_http_status :bad_request
        expect(response.parsed_body["errors"]).to include({ "anonymous_state" => "Anonymous discussions cannot be graded" })
      end

      it "allows partial_anonymity" do
        user_session @teacher
        post "create", params: topic_params(@course, { anonymous_state: "partial_anonymity" }), format: :json
        expect(response).to be_successful
        expect(DiscussionTopic.last.anonymous_state).to eq "partial_anonymity"
        expect(DiscussionTopic.last).to be_anonymous
      end

      it "nullifies anonymous_state when unaccounted for" do
        user_session @teacher
        post "create", params: topic_params(@course, { anonymous_state: "thisisunaccountedfor" }), format: :json
        expect(response).to be_successful
        expect(DiscussionTopic.last.anonymous_state).to be_nil
        expect(DiscussionTopic.last).not_to be_anonymous
      end
    end

    it "requires authorization to create a discussion" do
      @course.update_attribute(:is_public, true)
      post "create", params: topic_params(@course, { is_announcement: false }), format: :json
      assert_unauthorized
    end

    it "requires authorization to create an announcement" do
      @course.update_attribute(:is_public, true)
      post "create", params: topic_params(@course, { is_announcement: true }), format: :json
      assert_unauthorized
    end

    it "logs an asset access record for the discussion topic" do
      user_session(@student)
      post "create", params: topic_params(@course), format: :json
      accessed_asset = assigns[:accessed_asset]
      expect(accessed_asset[:category]).to eq "topics"
      expect(accessed_asset[:level]).to eq "participate"
    end

    it "creates an announcement that is not locked by default" do
      user_session(@teacher)
      params = topic_params(@course, { is_announcement: true })
      params.delete(:locked)
      post("create", params:, format: :json)
      expect(response).to be_successful
      expect(DiscussionTopic.last.locked).to be_falsy
    end

    it "creates a discussion topic that is not locked by default" do
      user_session(@teacher)
      params = topic_params(@course, { is_announcement: false })
      params.delete(:locked)
      post("create", params:, format: :json)
      expect(response).to be_successful
      expect(DiscussionTopic.last.locked).to be_falsy
    end

    it "registers a page view" do
      user_session(@student)
      post "create", params: topic_params(@course), format: :json
      page_view = assigns[:page_view]
      expect(page_view).not_to be_nil
      expect(page_view.http_method).to eq "post"
      expect(page_view.url).to match %r{^http://test\.host/api/v1/courses/\d+/discussion_topics}
      expect(page_view.participated).to be_truthy
    end

    it "does not dispatch assignment created notification for unpublished graded topics" do
      notification = Notification.create(name: "Assignment Created")
      obj_params = topic_params(@course).merge(assignment_params(@course))
      user_session(@teacher)
      post "create", params: obj_params, format: :json
      json = response.parsed_body
      topic = DiscussionTopic.find(json["id"])
      expect(topic).to be_unpublished
      expect(topic.assignment).to be_unpublished
      expect(@student.recent_stream_items.map { |item| item.data["notification_id"] }).not_to include notification.id
    end

    it "does not dispatch new topic notification when hidden by selective release" do
      Notification.create(name: "New Discussion Topic", category: "TestImmediately")
      @student.communication_channels.create!(path: "student@example.com") { |cc| cc.workflow_state = "active" }
      new_section = @course.course_sections.create!
      obj_params = topic_params(@course, published: true).merge(assignment_params(@course, only_visible_to_overrides: true, assignment_overrides: [{ course_section_id: new_section.id }]))
      user_session(@teacher)
      post "create", params: obj_params, format: :json
      json = response.parsed_body
      topic = DiscussionTopic.find(json["id"])
      expect(topic).to be_published
      expect(topic.assignment).to be_published
      expect(@student.email_channel.messages).to be_empty
      expect(@student.recent_stream_items.map(&:data)).not_to include topic
    end

    it "does dispatch new topic notification when not hidden" do
      Notification.create(name: "New Discussion Topic", category: "TestImmediately")
      @student.communication_channels.create!(path: "student@example.com") { |cc| cc.workflow_state = "active" }
      obj_params = topic_params(@course, published: true)
      user_session(@teacher)
      post "create", params: obj_params, format: :json
      json = response.parsed_body
      topic = DiscussionTopic.find(json["id"])
      expect(topic).to be_published
      expect(@student.email_channel.messages.map(&:context)).to include(topic)
    end

    it "does dispatch new topic notification when published" do
      Notification.create(name: "New Discussion Topic", category: "TestImmediately")
      @student.communication_channels.create!(path: "student@example.com") { |cc| cc.workflow_state = "active" }
      obj_params = topic_params(@course, published: false)
      user_session(@teacher)
      post "create", params: obj_params, format: :json

      json = response.parsed_body
      topic = DiscussionTopic.find(json["id"])
      expect(@student.email_channel.messages).to be_empty

      put "update", params: { course_id: @course.id, topic_id: topic.id, title: "Updated Topic", published: true }, format: "json"
      expect(@student.email_channel.messages.map(&:context)).to include(topic)
    end

    it "dispatches an assignment stream item with the correct title" do
      notification = Notification.create(name: "Assignment Created")
      obj_params = topic_params(@course)
                   .merge(assignment_params(@course))
                   .merge({ published: true })
      user_session(@teacher)
      post "create", params: obj_params, format: :json
      si = @student.recent_stream_items.detect do |item|
        item.data["notification_id"] == notification.id
      end
      expect(si.data["subject"]).to eq "Assignment Created - #{obj_params[:title]}, #{@course.name}"
    end

    it "does not allow for anonymous peer review assignment" do
      obj_params = topic_params(@course).merge(assignment_params(@course))
      obj_params[:assignment][:anonymous_peer_reviews] = true
      user_session(@teacher)
      post "create", params: obj_params, format: :json
      json = response.parsed_body
      expect(json["assignment"]["anonymous_peer_reviews"]).to be_falsey
    end

    context "usage rights - student" do
      let(:data) { fixture_file_upload("docs/txt.txt", "text/plain", true) }

      before { user_session(@student) }

      shared_examples_for "no usage rights set" do
        it "does not return usage rights on discussion topic attachment" do
          post "create", params: topic_params(@course, attachment: data), format: :json
          expect(Attachment.last.reload.usage_rights).to be_nil
        end
      end

      shared_examples_for "usage rights set" do
        it "returns usage rights on discussion topic attachment" do
          post "create", params: topic_params(@course, attachment: data), format: :json
          expect(Attachment.last.reload.usage_rights).not_to be_nil
        end
      end

      context "enabled on course" do
        before { @course.update!(usage_rights_required: true) }

        include_examples "usage rights set"
      end

      context "disabled on course" do
        before { @course.update!(usage_rights_required: false) }

        include_examples "no usage rights set"
      end
    end
  end

  describe "PUT: update" do
    before(:once) do
      @topic = DiscussionTopic.create!(context: @course,
                                       title: "Test Topic",
                                       delayed_post_at: "2013-01-01T00:00:00UTC",
                                       lock_at: "2013-01-02T00:00:00UTC")
    end

    before do
      user_session(@teacher)
    end

    describe "create_announcements_unlocked preference" do
      before do
        @teacher.create_announcements_unlocked(false)
        user_session(@teacher)
      end

      it "is not updated when updating an existing announcements" do
        topic = Announcement.create!(
          context: @course,
          title: "Test Announcement",
          message: "Foo",
          locked: "true"
        )
        put_params = { course_id: @course.id, topic_id: topic.id, locked: false }
        put("update", params: put_params)
        @teacher.reload
        expect(@teacher.create_announcements_unlocked?).to be_falsey
      end

      it "is not updated when creating an existing discussions" do
        topic = DiscussionTopic.create!(
          context: @course,
          title: "Test Topic",
          message: "Foo",
          locked: "true"
        )
        put_params = { course_id: @course.id, topic_id: topic.id, locked: false }
        put("update", params: put_params)
        @teacher.reload
        expect(@teacher.create_announcements_unlocked?).to be_falsey
      end
    end

    it "does not allow setting specific sections for group discussions" do
      user_session(@teacher)
      section1 = @course.course_sections.create!(name: "Section 1")
      section2 = @course.course_sections.create!(name: "Section 2")
      @course.enroll_teacher(@teacher, section: section1, allow_multiple_enrollments: true).accept(true)
      @course.enroll_teacher(@teacher, section: section2, allow_multiple_enrollments: true).accept(true)

      group_category = @course.group_categories.create(name: "gc")
      group = @course.groups.create!(group_category:)
      topic = DiscussionTopic.create!(context: group,
                                      title: "Test Topic",
                                      delayed_post_at: "2013-01-01T00:00:00UTC",
                                      lock_at: "2013-01-02T00:00:00UTC")
      put("update", params: {
            id: topic.id,
            group_id: group.id,
            topic_id: topic.id,
            specific_sections: section2.id,
            title: "Updated Topic",
          })
      expect(response).to have_http_status :unprocessable_entity
      expect(DiscussionTopic.count).to eq 2
      expect(DiscussionTopicSectionVisibility.count).to eq 0
    end

    it "does not allow updating a section specific announcement you do not have visibilities for" do
      user_session(@teacher)
      section1 = @course.course_sections.create!(name: "Section 1")
      section2 = @course.course_sections.create!(name: "Section 2")
      @course.enroll_teacher(@teacher, section: section1, allow_multiple_enrollments: true).accept!
      Enrollment.limit_privileges_to_course_section!(@course, @teacher, true)
      ann = @course.announcements.create!(message: "testing", is_section_specific: true, course_sections: [section2])
      ann.save!

      put("update", params: {
            course_id: @course.id,
            topic_id: ann.id,
            specific_sections: section1.id,
            title: "Updated Topic",
          })
      expect(response).to have_http_status :bad_request
    end

    it "Allows an admin to update a section-specific discussion" do
      account = @course.root_account
      section = @course.course_sections.create!(name: "Section")
      admin = account_admin_user(account:, role: admin_role, active_user: true)
      user_session(admin)
      topic = @course.discussion_topics.create!(title: "foo", message: "bar", user: @teacher)
      put("update", params: {
            course_id: @course.id,
            topic_id: topic.id,
            specific_sections: section.id,
            title: "foobers"
          })
      expect(response).to have_http_status :ok
    end

    it "triggers module progression recalculation if needed after changing sections" do
      @course.course_sections.create!(name: "Section")
      section2 = @course.course_sections.create!(name: "Section2")
      topic = @course.discussion_topics.create!(title: "foo", message: "bar", user: @teacher)
      mod = @course.context_modules.create!
      tag = mod.add_item({ id: topic.id, type: "discussion_topic" })
      mod.completion_requirements = { tag.id => { type: "must_view" } }
      mod.save!
      prog = mod.evaluate_for(@student)
      expect(prog).to be_unlocked

      user_session(@teacher)
      put "update", params: { course_id: @course.id, topic_id: topic.id, specific_sections: section2.id }
      expect(response).to be_successful

      expect(prog.reload).to be_completed
    end

    it "triggers module progression recalculation if undoing section specificness" do
      @course.course_sections.create!(name: "Section")
      section2 = @course.course_sections.create!(name: "Section2")
      topic = @course.discussion_topics.create!(title: "foo",
                                                message: "bar",
                                                user: @teacher,
                                                is_section_specific: true,
                                                course_sections: [section2])
      mod = @course.context_modules.create!
      tag = mod.add_item({ id: topic.id, type: "discussion_topic" })
      mod.completion_requirements = { tag.id => { type: "must_view" } }

      user_session(@teacher)
      expect_any_instantiation_of(mod).to receive(:invalidate_progressions)
      put "update", params: { course_id: @course.id, topic_id: topic.id, specific_sections: "all" }
      expect(response).to be_successful
    end

    it "can turn graded topic into ungraded section-specific topic in one edit" do
      user_session(@teacher)
      assign = @course.assignments.create!(title: "Graded Topic 1", submission_types: "discussion_topic")
      section1 = @course.course_sections.create!(name: "Section 1")
      @course.course_sections.create!(name: "Section 2")
      topic = assign.discussion_topic
      put("update", params: {
            course_id: @course.id,
            topic_id: topic.id,
            assignment: { set_assignment: "0" },
            specific_sections: section1.id
          })
      expect(response).to have_http_status :ok
      topic.reload
      expect(topic.assignment).to be_nil
    end

    it "does not clear lock_at if locked is not changed" do
      put("update", params: { course_id: @course.id,
                              topic_id: @topic.id,
                              title: "Updated Topic",
                              lock_at: @topic.lock_at,
                              delayed_post_at: @topic.delayed_post_at,
                              locked: false })
      expect(response).to have_http_status :ok
      expect(@topic.reload).not_to be_locked
      expect(@topic.lock_at).not_to be_nil
    end

    it "is able to turn off locked and delayed_post_at date in same request" do
      @topic.delayed_post_at = "2013-01-02T00:00:00UTC"
      @topic.locked = true
      @topic.save!
      put("update", params: { course_id: @course.id,
                              topic_id: @topic.id,
                              title: "Updated Topic",
                              locked: false,
                              delayed_post_at: nil })
      expect(response).to have_http_status :ok
      expect(assigns[:topic].title).to eq "Updated Topic"
      expect(assigns[:topic].locked).to be false
      expect(assigns[:topic].delayed_post_at).to be_nil
      expect(@topic.reload).not_to be_locked
      expect(@topic.delayed_post_at).to be_nil
    end

    it "is able to turn on locked and delayed_post_at date in same request" do
      @topic.delayed_post_at = nil
      @topic.locked = false
      @topic.save!
      delayed_post_time = Time.zone.local(2018, 4, 15)
      put("update", params: { course_id: @course.id,
                              topic_id: @topic.id,
                              title: "Updated Topic",
                              locked: true,
                              delayed_post_at: delayed_post_time.to_s })
      expect(response).to have_http_status :ok
      expect(assigns[:topic].title).to eq "Updated Topic"
      expect(assigns[:topic].locked).to be true
      expect(assigns[:topic].delayed_post_at.year).to eq 2018
      expect(assigns[:topic].delayed_post_at.month).to eq 4
      expect(@topic.reload).to be_locked
      expect(@topic.delayed_post_at.year).to eq 2018
      expect(@topic.delayed_post_at.month).to eq 4
    end

    it "does not change the editor if only pinned was changed" do
      put("update", params: { course_id: @course.id, topic_id: @topic.id, pinned: "1" }, format: "json")
      @topic.reload
      expect(@topic.pinned).to be_truthy
      expect(@topic.editor).to_not eq @teacher
    end

    it "does not clear delayed_post_at if published is not changed" do
      @topic.workflow_state = "post_delayed"
      @topic.save!
      put("update", params: { course_id: @course.id,
                              topic_id: @topic.id,
                              title: "Updated Topic",
                              lock_at: @topic.lock_at,
                              delayed_post_at: @topic.delayed_post_at,
                              published: false })
      expect(@topic.reload).not_to be_published
      expect(@topic.delayed_post_at).not_to be_nil
    end

    it "unlocks discussions with a lock_at attribute if lock state changes" do
      @topic.lock!
      put("update", params: { course_id: @course.id,
                              topic_id: @topic.id,
                              title: "Updated Topic",
                              lock_at: @topic.lock_at,
                              delayed_post_at: @topic.delayed_post_at,
                              locked: false })

      expect(@topic.reload).not_to be_locked
      expect(@topic.lock_at).to be_nil
    end

    it "sets workflow to post_delayed when delayed_post_at and lock_at are in the future" do
      put(:update, params: { course_id: @course.id,
                             topic_id: @topic.id,
                             title: "Updated topic",
                             delayed_post_at: 5.days.from_now })
      expect(@topic.reload).to be_post_delayed
    end

    it "does not clear lock_at if lock state hasn't changed" do
      put("update", params: { course_id: @course.id,
                              topic_id: @topic.id,
                              title: "Updated Topic",
                              lock_at: @topic.lock_at,
                              locked: true })
      expect(@topic.reload).to be_locked
      expect(@topic.lock_at).not_to be_nil
    end

    it "sets draft state on discussions with delayed_post_at" do
      put("update", params: { course_id: @course.id,
                              topic_id: @topic.id,
                              title: "Updated Topic",
                              lock_at: @topic.lock_at,
                              delayed_post_at: @topic.delayed_post_at,
                              published: false })

      expect(@topic.reload).not_to be_published
    end

    it "attaches a file and handles duplicates" do
      data = fixture_file_upload("docs/txt.txt", "text/plain", true)
      attachment_model context: @course, uploaded_data: data, folder: Folder.unfiled_folder(@course)
      put "update", params: { course_id: @course.id, topic_id: @topic.id, attachment: data }, format: "json"
      expect(response).to be_successful
      json = JSON.parse(response.body) # rubocop:disable Rails/ResponseParsedBody
      new_file = Attachment.find(json["attachments"][0]["id"])
      expect(new_file.display_name).to match(/txt-[0-9]+\.txt/)
      expect(json["attachments"][0]["display_name"]).to eq new_file.display_name
    end

    it "deletes attachments" do
      attachment = @topic.attachment = attachment_model(context: @course)
      @topic.lock_at = 1.week.from_now
      @topic.delayed_post_at = 1.week.ago
      @topic.save!
      @topic.unlock!
      put("update", params: { course_id: @course.id, topic_id: @topic.id, remove_attachment: "1" }, format: "json")
      expect(response).to be_successful

      expect(@topic.reload.attachment).to be_nil
      expect(attachment.reload).to be_deleted
    end

    it "does not create a new discussion if the storage usage would be greater than the quota" do
      @course.storage_quota = 60.kilobytes
      @course.save!
      old_count = DiscussionTopic.count
      # the doc.doc is a 63 kb file
      data = fixture_file_upload("docs/doc.doc", "application/msword", true)
      post "create", params: topic_params(@course, { attachment: data }), format: :json
      expect(response).to have_http_status :bad_request
      expect(response.body).to include("Course storage quota exceeded")
      expect(DiscussionTopic.count).to eq old_count
    end

    it "uses inst-fs if it is enabled" do
      uuid = "1234-abcd"
      allow(InstFS).to receive_messages(enabled?: true, direct_upload: uuid)

      data = fixture_file_upload("docs/txt.txt", "text/plain", true)
      attachment_model context: @course, uploaded_data: data, folder: Folder.unfiled_folder(@course)
      put "update", params: { course_id: @course.id, topic_id: @topic.id, attachment: data }, format: "json"

      @topic.reload
      expect(@topic.attachment.instfs_uuid).to eq(uuid)
    end

    it "editing section-specific topic to not-specific should clear out visibilities" do
      @announcement = Announcement.create!(context: @course,
                                           title: "Test Announcement",
                                           message: "Foo",
                                           delayed_post_at: "2013-01-01T00:00:00UTC",
                                           lock_at: "2013-01-02T00:00:00UTC")
      section1 = @course.course_sections.create!(name: "Section 1")
      section2 = @course.course_sections.create!(name: "Section 2")
      @announcement.is_section_specific = true
      @announcement.course_sections = [section1, section2]
      @announcement.save!
      put("update", params: { course_id: @course.id,
                              topic_id: @announcement.id,
                              message: "Foobar",
                              is_announcement: true,
                              specific_sections: "all" })
      expect(response).to be_successful
      visibilities = DiscussionTopicSectionVisibility.active
                                                     .where(discussion_topic_id: @announcement.id)
      expect(visibilities.empty?).to be true
    end

    it "does not remove specific sections if key is missing in PUT json" do
      @announcement = Announcement.create!(context: @course,
                                           title: "Test Announcement",
                                           message: "Foo",
                                           delayed_post_at: "2013-01-01T00:00:00UTC",
                                           lock_at: "2013-01-02T00:00:00UTC")
      section1 = @course.course_sections.create!(name: "Section 1")
      section2 = @course.course_sections.create!(name: "Section 2")
      @announcement.is_section_specific = true
      @announcement.course_sections = [section1, section2]
      @announcement.save!

      put("update", params: { course_id: @course.id,
                              topic_id: @announcement.id,
                              message: "Foobar",
                              is_announcement: true })
      expect(response).to be_successful
      visibilities = DiscussionTopicSectionVisibility.active
                                                     .where(discussion_topic_id: @announcement.id)
      expect(visibilities.count).to eq 2
    end

    context "anonymous discussion and group discussion relationship" do
      it "returns an error when turning a fully anonymous discussion into a group discussion" do
        full_anon = @course.discussion_topics.create!(title: "foo", message: "bar", user: @teacher, anonymous_state: "full_anonymity")
        group_category = @course.group_categories.create(name: "gc")
        @course.groups.create!(group_category:)
        user_session(@teacher)
        put "update", params: { course_id: @course.id, topic_id: full_anon.id, group_category_id: group_category.id }, format: "json"
        expect(response).to have_http_status :bad_request
        expect(response.parsed_body["errors"]).to include({ "anonymous_state" => "Group discussions cannot be anonymous." })
      end

      it "returns an error when turning a partially anonymous discussion into a group discussion" do
        partial_anon = @course.discussion_topics.create!(title: "foo", message: "bar", user: @teacher, anonymous_state: "partial_anonymity")
        group_category = @course.group_categories.create(name: "gc")
        @course.groups.create!(group_category:)
        user_session(@teacher)
        put "update", params: { course_id: @course.id, topic_id: partial_anon.id, group_category_id: group_category.id }, format: "json"
        expect(response).to have_http_status :bad_request
        expect(response.parsed_body["errors"]).to include({ "anonymous_state" => "Group discussions cannot be anonymous." })
      end

      it "saves when turning a regular discussion into a group discussion" do
        regular_discussion = @course.discussion_topics.create!(title: "foo", message: "bar", user: @teacher)
        group_category = @course.group_categories.create(name: "gc")
        @course.groups.create!(group_category:)
        user_session(@teacher)
        put "update", params: { course_id: @course.id, topic_id: regular_discussion.id, group_category_id: group_category.id }, format: "json"
        expect(response).to be_successful
        expect(regular_discussion.reload.group_category).to eq group_category
      end

      it "allows the update to fully anonymous, when discussion is edited to be ungraded at the same time" do
        obj_params = topic_params(@course).merge(assignment_params(@course))
        user_session(@teacher)
        post "create", params: obj_params, format: :json
        expect(response).to be_successful

        topic = DiscussionTopic.last
        put "update",
            params: {
              course_id: @course.id,
              topic_id: topic.id,
              anonymous_state: "full_anonymity",
              assignment: { set_assignment: false }
            },
            format: "json"
        expect(response).to be_successful
      end
    end
  end

  describe "POST 'reorder'" do
    it "reorders pinned topics" do
      user_session(@teacher)

      # add noise
      @course.announcements.create!(message: "asdf")
      course_topic

      topics = Array.new(3) { course_topic(pinned: true) }
      expect(topics.map(&:position)).to eq [1, 2, 3]
      t1, t2, _ = topics
      post "reorder", params: { course_id: @course.id, order: "#{t2.id},#{t1.id}" }, format: "json"
      expect(response).to be_successful
      topics.each(&:reload)
      expect(topics.map(&:position)).to eq [2, 1, 3]
    end
  end

  describe "Horizon course" do
    before do
      allow(@course).to receive(:horizon_course?).and_return(true)
    end

    it "does not let create/edit discussions" do
      user_session @teacher
      expect do
        @course.discussion_topics.create!(title: "some topic")
      end.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "lets create/edit announcements" do
      user_session @teacher
      @course.announcements.create!(message: "some topic123")
      expect(@course.announcements.last.message).to eq "some topic123"
    end
  end

  describe "Metrics" do
    before do
      allow(InstStatsd::Statsd).to receive(:distributed_increment)
      allow(InstStatsd::Statsd).to receive(:count)
    end

    it "increment discussion_topic.created" do
      user_session @teacher
      post "create", params: topic_params(@course), format: :json
      expect(response).to be_successful
      expect(InstStatsd::Statsd).to have_received(:distributed_increment).with("discussion_topic.created").at_least(:once)
    end

    it "does not increment discussion_topic.created when topic is not successfully created" do
      user_session @observer
      post "create", params: topic_params(@course), format: :json
      expect(response).to have_http_status :forbidden
      expect(InstStatsd::Statsd).not_to have_received(:distributed_increment).with("discussion_topic.created")
    end

    it "increment discussion_topic.created.partial_anonymity" do
      user_session @teacher
      post "create", params: topic_params(@course, { anonymous_state: "partial_anonymity" }), format: :json
      expect(response).to be_successful
      expect(InstStatsd::Statsd).to have_received(:distributed_increment).with("discussion_topic.created.partial_anonymity").at_least(:once)
    end

    it "increment discussion_topic.created.full_anonymity" do
      user_session @teacher
      post "create", params: topic_params(@course, { anonymous_state: "full_anonymity" }), format: :json
      expect(response).to be_successful
      expect(InstStatsd::Statsd).to have_received(:distributed_increment).with("discussion_topic.created.full_anonymity").at_least(:once)
    end

    it "increment discussion_topic.created.podcast_feed_enabled" do
      user_session @teacher
      post "create", params: topic_params(@course, { podcast_enabled: 1 }), format: :json
      expect(response).to be_successful
      expect(InstStatsd::Statsd).to have_received(:distributed_increment).with("discussion_topic.created.podcast_feed_enabled").at_least(:once)
    end

    it "does not increment discussion_topic.created.podcast_feed_enabled" do
      user_session @teacher
      post "create", params: topic_params(@course, { podcast_enabled: 0 }), format: :json
      expect(response).to be_successful
      expect(InstStatsd::Statsd).not_to have_received(:distributed_increment).with("discussion_topic.created.podcast_feed_enabled")
    end

    it "increment discussion_topic.created.allow_liking_enabled" do
      user_session @teacher
      post "create", params: topic_params(@course, { allow_rating: 1 }), format: :json
      expect(response).to be_successful
      expect(InstStatsd::Statsd).to have_received(:distributed_increment).with("discussion_topic.created.allow_liking_enabled").at_least(:once)
    end

    it "does not increment discussion_topic.created.allow_liking_enabled" do
      user_session @teacher
      post "create", params: topic_params(@course, { allow_rating: 0 }), format: :json
      expect(response).to be_successful
      expect(InstStatsd::Statsd).not_to have_received(:distributed_increment).with("discussion_topic.created.allow_liking_enabled")
    end

    it "increment discussion_topic.created.attachment" do
      user_session @teacher
      data = fixture_file_upload("docs/txt.txt", "text/plain", true)
      attachment_model context: @course, uploaded_data: data, folder: Folder.unfiled_folder(@course)
      post "create", params: topic_params(@course, { attachment: data }), format: :json
      expect(response).to be_successful
      expect(InstStatsd::Statsd).to have_received(:distributed_increment).with("discussion_topic.created.attachment").at_least(:once)
    end

    it "does not increment discussion_topic.created.attachment" do
      user_session @teacher
      post "create", params: topic_params(@course, {}), format: :json
      expect(response).to be_successful
      expect(InstStatsd::Statsd).not_to have_received(:distributed_increment).with("discussion_topic.created.attachment")
    end

    it "increment discussion_topic.created.scheduled when delayed_post_at is not nil" do
      user_session @teacher
      post "create", params: topic_params(@course, { delayed_post_at: "2022-04-21T06:00:00.000Z" }), format: :json
      expect(response).to be_successful
      expect(InstStatsd::Statsd).to have_received(:distributed_increment).with("discussion_topic.created.scheduled").at_least(:once)
    end

    it "increment discussion_topic.created.scheduled when lock at is not nil" do
      user_session @teacher
      post "create", params: topic_params(@course, { lock_at: "2022-04-21T06:00:00.000Z" }), format: :json
      expect(response).to be_successful
      expect(InstStatsd::Statsd).to have_received(:distributed_increment).with("discussion_topic.created.scheduled").at_least(:once)
    end

    it "does not increment discussion_topic.created.scheduled without delayed_post_at and lock_at" do
      user_session @teacher
      post "create", params: topic_params(@course), format: :json
      expect(response).to be_successful
      expect(InstStatsd::Statsd).not_to have_received(:distributed_increment).with("discussion_topic.created.scheduled")
    end

    it "increment discussion_topic.created.graded" do
      user_session @teacher
      obj_params = topic_params(@course).merge(assignment_params(@course))
      post "create", params: obj_params, format: :json
      expect(InstStatsd::Statsd).to have_received(:distributed_increment).with("discussion_topic.created.graded").at_least(:once)
    end

    it "does not increment discussion_topic.created.graded for non graded topics" do
      user_session @teacher
      post "create", params: topic_params(@course), format: :json
      expect(InstStatsd::Statsd).not_to have_received(:distributed_increment).with("discussion_topic.created.graded")
    end

    describe "assignment multiple due dates" do
      describe "should increment" do
        it "discussion_topic.created.multiple_due_dates" do
          user_session @teacher
          obj_params = topic_params(@course).merge(assignment_params(@course))
          obj_params[:assignment][:assignment_overrides] = [{ "due_at" => "2022-04-23T05:59:59.000Z", "due_at_overridden" => false, "lock_at" => "2022-04-24T05:59:59.000Z", "lock_at_overridden" => false, "unlock_at" => "2022-04-21T06:00:00.000Z", "unlock_at_overridden" => false, "rowKey" => "0", "course_section_id" => "2", "title" => "Section 1", "all_day" => false, "all_day_date" => nil, "persisted" => false },
                                                            { "due_at" => "2022-04-30T05:59:59.000Z", "due_at_overridden" => false, "lock_at" => "2022-05-01T05:59:59.000Z", "lock_at_overridden" => false, "unlock_at" => "2022-04-28T06:00:00.000Z", "unlock_at_overridden" => false, "rowKey" => "1", "course_section_id" => "3", "title" => "Section 2", "all_day" => false, "all_day_date" => nil, "persisted" => false }]
          post "create", params: obj_params, format: :json
          expect(InstStatsd::Statsd).to have_received(:distributed_increment).with("discussion_topic.created.multiple_due_dates").at_least(:once)
        end
      end

      describe "should not increment" do
        it "discussion_topic.created.multiple_due_dates" do
          user_session @teacher
          post "create", params: topic_params(@course), format: :json
          expect(InstStatsd::Statsd).not_to have_received(:distributed_increment).with("discussion_topic.created.multiple_due_dates")
        end
      end
    end

    it "increment discussion_topic.visit.redesign" do
      course_topic
      user_session @teacher
      get "show", params: { course_id: @course.id, id: @topic.id }
      expect(InstStatsd::Statsd).to have_received(:distributed_increment).with("discussion_topic.visit.redesign").at_least(:once)
    end

    it "does not increment discussion_topic.visit.redesign with unauthorized visit" do
      course_topic
      get "show", params: { course_id: @course.id, id: @topic.id }
      assert_unauthorized
      expect(InstStatsd::Statsd).not_to have_received(:distributed_increment).with("discussion_topic.visit.redesign")
    end

    it "count discussion_topic.visit.entries.redesign" do
      course_topic
      user_session @teacher
      get "show", params: { course_id: @course.id, id: @topic.id }
      expect(InstStatsd::Statsd).to have_received(:count).with("discussion_topic.visit.entries.redesign", 0).at_least(:once)
    end

    it "does not count discussion_topic.visit.entries.redesign with unauthorized visit" do
      course_topic
      get "show", params: { course_id: @course.id, id: @topic.id }
      assert_unauthorized
      expect(InstStatsd::Statsd).not_to have_received(:count).with("discussion_topic.visit.entries.redesign", 0)
    end

    it "count discussion_topic.visit.pages.redesign" do
      course_topic
      user_session @teacher
      get "show", params: { course_id: @course.id, id: @topic.id }
      expect(InstStatsd::Statsd).to have_received(:count).with("discussion_topic.visit.pages.redesign", 0).at_least(:once)
    end

    it "does not count discussion_topic.visit.pages.redesign with unauthorized visit" do
      course_topic
      get "show", params: { course_id: @course.id, id: @topic.id }
      assert_unauthorized
      expect(InstStatsd::Statsd).not_to have_received(:count).with("discussion_topic.visit.pages.redesign", 0)
    end

    it "increment discussion_topic.created.group" do
      user_session @teacher
      @group_category = @course.group_categories.create(name: "gc")
      @group = @course.groups.create!(group_category: @group_category)

      post "create", params: group_topic_params(@group), format: :json
      expect(response).to be_successful
      expect(InstStatsd::Statsd).to have_received(:distributed_increment).with("discussion_topic.created.group").at_least(:once)
    end

    it "does not increment discussion_topic.created.group when topic is not successfully created" do
      user_session @teacher
      post "create", params: topic_params(@course), format: :json
      expect(InstStatsd::Statsd).not_to have_received(:distributed_increment).with("discussion_topic.created.group")
    end
  end
end
