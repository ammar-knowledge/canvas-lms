# frozen_string_literal: true

#
# Copyright (C) 2014 - present Instructure, Inc.
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

require_relative "../helpers/conversations_common"

describe "conversations new" do
  include_context "in-process server selenium tests"
  include ConversationsCommon

  before do
    conversation_setup
    @s1 = user_factory(name: "first student")
    @s2 = user_factory(name: "second student")
    @s3 = user_factory(name: "third student")
    [@s1, @s2, @s3].each { |s| @course.enroll_student(s).update_attribute(:workflow_state, "active") }
    cat = @course.group_categories.create(name: "the groups")
    @group = cat.groups.create(name: "the group", context: @course)
    @group.users = [@s1, @s2]
    @t2 = user_factory(name: "second teacher", active_user: true)
    @course.enroll_teacher(@t2)
  end

  describe "message sending" do
    context "react_inbox", :ignore_js_errors do
      context "date restricted courses" do
        before do
          @course.restrict_enrollments_to_course_dates = true
          @course.restrict_student_past_view = true
          @course.restrict_student_future_view = true
          @course.save!
        end

        context "soft concluded course" do
          before do
            @course.conclude_at = 1.day.ago
            @course.start_at = 2.days.ago
            @course.save!
          end

          it "does not allow a student to create a new conversation when course is soft concluded" do
            user_session(@s1)

            get "/conversations"
            f("button[data-testid='compose']").click
            f("input[placeholder='Select Course']").click

            # Groups that are a part of a concluded course should not be visible
            expect(@group.context).to eq(@course)
            expect(f("body")).to_not contain_jqcss("span:contains('#{@group.name}')")
            expect(f("body")).to_not contain_jqcss("li:contains('#{@course.name}')")
          end

          it "does not allow a teacher to create a new conversation when course is soft concluded" do
            user_session(@teacher)

            get "/conversations"
            f("button[data-testid='compose']").click
            f("input[placeholder='Select Course']").click
            fj("li:contains('#{@course.name}')").click
            f("input[aria-label='To']").click
            wait_for_ajaximations
            fj("li:contains('Students')").click
            wait_for_ajaximations
            fj("li:contains('#{@s1.name}')").click
            f("textarea[data-testid='message-body']").send_keys "Message to Teacher in soft concluded course"
            fj("button:contains('Send')").click
            wait_for_ajaximations

            expect(fj("div:contains('Course concluded, unable to send messages')")).to be_present
          end

          it "does not allow an observer to create a new conversation when course is soft concluded" do
            observer_in_course(name: "Collins Ryan", active_all: true, associated_user_id: @s1).user

            user_session(@observer)
            get "/conversations"
            f("button[data-testid='compose']").click
            f("input[placeholder='Select Course']").click
            expect(f("body")).to_not contain_jqcss("li:contains('#{@course.name}')")
          end
        end
      end

      context "when user_id and user_name url params exist" do
        it "properly sends a message based on url params" do
          site_admin_logged_in
          get "/conversations?embed=true&&user_name=#{@s1.name}&&user_id=#{@s1.id}"
          expect(fj("h2:contains('Compose Message')")).to be_present
          expect(fj("span[data-testid='address-book-tag'] button:contains(#{@s1.name})")).to be_present
          f("textarea[data-testid='message-body']").send_keys "confirm if you get this!"
          fj("button:contains('Send')").click
          wait_for_ajaximations
          cm = ConversationMessage.last
          expect(cm.conversation_message_participants.pluck(:user_id)).to match_array [@s1.id, @admin.id]
          expect(cm.body).to eq "confirm if you get this!"

          f("button[data-testid='compose']").click
          wait_for_ajaximations
          expect(f("body")).not_to contain_jqcss("span[data-testid='address-book-tag'] button:contains(#{@s1.name})")
        end
      end

      context "shows correct address book items" do
        context "for teacher" do
          before do
            user_session(@teacher)
          end

          it "correctly shows course options", priority: "1" do
            get "/conversations"
            open_react_compose_modal_addressbook

            # all in course, Teachers, Students, Student Groups
            expect(ff("div[data-testid='address-book-item']").count).to eq(4)
            expect(fj("div[data-testid='address-book-item']:contains('All in #{@course.name}')")).to be_present
            expect(fj("div[data-testid='address-book-item']:contains('People: #{@course.users.count}')")).to be_present
          end

          it "opens the addressbook when clicking the address-book icon", priority: "1" do
            get "/conversations"

            # Open compose modal
            f("button[data-testid='compose']").click

            # select the only course option
            f("input[placeholder='Select Course']").click
            f("li[role='none']").click

            # Open address book using the ICON
            force_click("button[data-testid='address-button']")

            # all in course, Teachers, Students, Student Groups
            expect(ff("div[data-testid='address-book-item']").count).to eq(4)
            expect(fj("div[data-testid='address-book-item']:contains('All in #{@course.name}')")).to be_present
            expect(fj("div[data-testid='address-book-item']:contains('People: #{@course.users.count}')")).to be_present
          end

          it "correctly shows Teachers option", priority: "1" do
            get "/conversations"
            open_react_compose_modal_addressbook

            fj("div[data-testid='address-book-item']:contains('Teachers')").click
            wait_for_ajaximations
            # back, all in Teachers, @Teacher name, @t2 name
            expect(ff("div[data-testid='address-book-item']").count).to eq(4)
            expect(fj("div[data-testid='address-book-item']:contains('All in Teachers')")).to be_present
            expect(fj("div[data-testid='address-book-item']:contains('People: #{@course.teachers.count}')")).to be_present
          end

          it "correctly shows Observers option" do
            observer_in_course(name: "Scott Summers", active_all: true, associated_user_id: @s1).user
            o2 = observer_in_course(name: "Collins Ryan", active_all: true, associated_user_id: @s2).user

            enrollment = @course.enroll_user(o2, "ObserverEnrollment")
            enrollment.associated_user = @s3
            enrollment.workflow_state = "active"
            enrollment.save

            get "/conversations"
            open_react_compose_modal_addressbook

            fj("div[data-testid='address-book-item']:contains('Observers')").click
            wait_for_ajaximations
            # back, all in Observers, @Observer1 Name, @Observer2 Name
            expect(ff("div[data-testid='address-book-item']").count).to eq(4)
            expect(fj("div[data-testid='address-book-item']:contains('Scott Summers')")).to be_present
            expect(fj("div[data-testid='address-book-item']:contains('Observing: first student')")).to be_present
            expect(fj("div[data-testid='address-book-item']:contains('Collins Ryan')")).to be_present
            expect(fj("div[data-testid='address-book-item']:contains('Observing: second student, third student')")).to be_present
          end

          it "correctly shows students option", priority: "1" do
            get "/conversations"
            open_react_compose_modal_addressbook

            fj("div[data-testid='address-book-item']:contains('Students')").click
            wait_for_ajaximations
            # back, all in Students, @s1 name, @s2 name, @s3 name
            expect(ff("div[data-testid='address-book-item']").count).to eq(5)
            expect(fj("div[data-testid='address-book-item']:contains('All in Students')")).to be_present
            expect(fj("div[data-testid='address-book-item']:contains('People: #{@course.students.count}')")).to be_present
          end

          # There is no option to send a message to all groups
          it "correctly shows student groups option", priority: "1" do
            get "/conversations"
            open_react_compose_modal_addressbook

            fj("div[data-testid='address-book-item']:contains('Student Groups')").click
            wait_for_ajaximations

            # back, @group name
            expect(ff("div[data-testid='address-book-item']").count).to eq(2)
          end

          it "correctly shows student group option", priority: "1" do
            get "/conversations"
            open_react_compose_modal_addressbook

            fj("div[data-testid='address-book-item']:contains('Student Groups')").click
            wait_for_ajaximations
            fj("div[data-testid='address-book-item']:contains('#{@group.name}')").click
            wait_for_ajaximations

            # Back, all in the group, @s1, @s2
            expect(ff("div[data-testid='address-book-item']").count).to eq(4)
            expect(fj("div[data-testid='address-book-item']:contains('All in #{@group.name}')")).to be_present
            expect(fj("div[data-testid='address-book-item']:contains('People: #{@group.users.count}')")).to be_present
          end
        end

        context "for student" do
          before do
            user_session(@s1)
            get "/conversations"
          end

          it "does not show student the all in course option by default", priority: "1" do
            # Teachers, Students, Student Groups
            open_react_compose_modal_addressbook
            expect(ff("div[data-testid='address-book-item']").count).to eq(3)
            expect(f("body")).not_to contain_jqcss("div[data-testid='address-book-item']:contains('Back')")
            expect(fj("div[data-testid='address-book-item']:contains('Teachers')")).to be_displayed
            expect(fj("div[data-testid='address-book-item']:contains('Students')")).to be_displayed
            expect(fj("div[data-testid='address-book-item']:contains('Student Groups')")).to be_displayed
          end

          it "correctly shows student the all in course option if send_messages_all is set to true", priority: "1" do
            # all in course, Teachers, Students, Student Groups
            @course.account.role_overrides.create!(permission: :send_messages_all, role: student_role, enabled: true)
            open_react_compose_modal_addressbook
            expect(ff("div[data-testid='address-book-item']").count).to eq(4)
            expect(fj("div[data-testid='address-book-item']:contains('All in #{@course.name}')")).to be_present
            expect(fj("div[data-testid='address-book-item']:contains('People: #{@course.users.count}')")).to be_present
          end
        end
      end

      context "correctly sends messages to contexts as a teacher" do
        before do
          user_session(@teacher)
          get "/conversations"
          f("button[data-testid='compose']").click
          f("input[placeholder='Select Course']").click
          fj("li:contains('#{@course.name}')").click
          f("input[aria-label='To']").click
        end

        it "correctly sends message to the entire course", priority: "1" do
          fj("div[data-testid='address-book-item']:contains('All in #{@course.name}')").click
          expect(fj("span[data-testid='address-book-tag']:contains('All in #{@course.name}')")).to be_present

          f("textarea[data-testid='message-body']").send_keys "hallo!"
          fj("button:contains('Send')").click
          wait_for_ajaximations

          expect(@s2.conversations.last.conversation.conversation_participants.collect(&:user_id).sort).to eq([@teacher, @t2, @s1, @s2, @s3].collect(&:id).sort)
        end

        it "correctly sends message to all teachers", priority: "1" do
          fj("div[data-testid='address-book-item']:contains('Teachers')").click
          wait_for_ajaximations

          fj("div[data-testid='address-book-item']:contains('All in Teachers')").click
          expect(fj("span[data-testid='address-book-tag']:contains('All in Teachers')")).to be_present

          f("textarea[data-testid='message-body']").send_keys "hallo!"
          fj("button:contains('Send')").click
          wait_for_ajaximations

          expect(@t2.conversations.last.conversation.conversation_participants.collect(&:user_id).sort).to eq([@teacher, @t2].collect(&:id).sort)
        end

        it "correctly wipes Search after cancelling compose", priority: "1" do
          fj("div[data-testid='address-book-item']:contains('Teachers')").click
          wait_for_ajaximations

          fj("div[data-testid='address-book-item']:contains('All in Teachers')").click
          expect(fj("span[data-testid='address-book-tag']:contains('All in Teachers')")).to be_present

          fj("button:contains('Cancel')").click
          wait_for_ajaximations

          f("button[data-testid='compose']").click
          expect(f("body")).not_to contain_jqcss("div[data-testid='address-book-item']:contains('All in Teachers')")
        end

        it "correctly sends message to all students", priority: "1" do
          fj("div[data-testid='address-book-item']:contains('Students')").click
          wait_for_ajaximations

          fj("div[data-testid='address-book-item']:contains('All in Students')").click
          expect(fj("span[data-testid='address-book-tag']:contains('All in Students')")).to be_present

          f("textarea[data-testid='message-body']").send_keys "hallo!"
          fj("button:contains('Send')").click
          wait_for_ajaximations

          expect(@s2.conversations.last.conversation.conversation_participants.collect(&:user_id).sort).to eq([@teacher, @s1, @s2, @s3].collect(&:id).sort)
        end

        it "correctly sends message to the entire student group", priority: "1" do
          fj("div[data-testid='address-book-item']:contains('Student Groups')").click
          wait_for_ajaximations
          fj("div[data-testid='address-book-item']:contains('#{@group.name}')").click
          wait_for_ajaximations
          fj("div[data-testid='address-book-item']:contains('All in #{@group.name}')").click

          expect(fj("span[data-testid='address-book-tag']:contains('All in #{@group.name}')")).to be_present

          f("textarea[data-testid='message-body']").send_keys "hallo!"
          fj("button:contains('Send')").click
          wait_for_ajaximations

          expect(@s2.conversations.last.conversation.conversation_participants.collect(&:user_id).sort).to eq([@teacher, @s1, @s2].collect(&:id).sort)
        end
      end

      it "lets admins send a message without context" do
        admin_logged_in
        get "/conversations"
        f("button[data-testid='compose']").click
        f("input[aria-label='To']").click
        wait_for_ajaximations
        fj("li:contains('Users')").click
        fj("li:contains('#{@s1.name}')").click
        f("input[aria-label='To']").click
        wait_for_ajaximations
        fj("li:contains('#{@s2.name}')").click
        f("textarea[data-testid='message-body']").send_keys "sent to both of you"
        fj("button:contains('Send')").click
        wait_for_ajaximations
        expect(@s1.conversations.last.conversation.conversation_participants.collect(&:user_id).sort).to eq [@s1.id, @s2.id, @admin.id]
        expect(@s1.conversations.last.conversation.context).to eq @admin.account
      end

      it "sets compose course when course filter is set" do
        get "/conversations"

        f("[data-testid = 'course-select']").click
        wait_for_ajaximations
        fj("li > span:contains('#{@course.name}')").click
        f("button[data-testid='compose']").click

        expect(f("input[data-testid = 'course-select']").property("value")).to eq(@course.name)

        f("input[aria-label='To']").click
        expect(fj("li:contains('All in #{@course.name}')")).to be_displayed
      end

      context "differentiation tags" do
        before do
          Account.default.enable_feature! :assign_to_differentiation_tags
          Account.default.settings[:allow_assign_to_differentiation_tags] = { value: true }
          Account.default.save!
          Account.default.reload
          @non_collaborative_group_category = @course.group_categories.create!(name: "Test differentiation tag", non_collaborative: true)
          @non_collaborative_group = @course.groups.create!(name: "Test differentiation tag", group_category: @non_collaborative_group_category)
          @non_collaborative_group.add_user(@s1)
          @non_collaborative_group.add_user(@s2)
        end

        describe "as a teacher" do
          before do
            user_session(@teacher)
            get "/conversations"
            f("button[data-testid='compose']").click
            f("input[placeholder='Select Course']").click
            fj("li:contains('#{@course.name}')").click
            f("input[aria-label='To']").click
          end

          it "correctly sends messages to differentiation tag" do
            fj("div[data-testid='address-book-item']:contains('Differentiation Tags')").click
            wait_for_ajaximations
            fj("div[data-testid='address-book-item']:contains('differentiation tag')").click
            wait_for_ajaximations
            fj("div[data-testid='address-book-item']:contains('All in #{@non_collaborative_group.name}')").click
            wait_for_ajaximations
            expect(f("input[data-testid='individual-message-checkbox']")).to be_disabled
            expect(f("input[data-testid='individual-message-checkbox']").attribute("checked")).to eq "true"
            f("textarea[data-testid='message-body']").send_keys "hallo!"
            wait_for_ajaximations
            fj("button:contains('Send')").click
            wait_for_ajaximations

            # Verify that the message was sent to both students in the group, but as separate conversations
            expect(@s1.conversations.last.conversation.conversation_participants.collect(&:user_id).sort).to eq([@teacher, @s1].collect(&:id).sort)
            expect(@s2.conversations.last.conversation.conversation_participants.collect(&:user_id).sort).to eq([@teacher, @s2].collect(&:id).sort)

            expect(@s1.conversations.last.conversation.conversation_messages.first.body).to eq "hallo!"
            expect(@s2.conversations.last.conversation.conversation_messages.first.body).to eq "hallo!"
          end

          it "does not show all in option for differentiation tags" do
            fj("div[data-testid='address-book-item']:contains('Differentiation Tags')").click
            wait_for_ajaximations
            expect(f("body")).not_to contain_jqcss("div[data-testid='address-book-item']:contains('All in Differentiation Tags')")
          end
        end

        describe "as a student" do
          before do
            user_session(@s1)
            get "/conversations"
            f("button[data-testid='compose']").click
            f("input[placeholder='Select Course']").click
            fj("li:contains('#{@course.name}')").click
            f("input[aria-label='To']").click
          end

          it "does not show differentiation tags" do
            expect(f("body")).not_to contain_jqcss("div[data-testid='address-book-item']:contains('Differentiation Tags')")
          end
        end
      end

      context "individual message sending" do
        it "allows messages to be sent individually for account-level groups", priority: "2" do
          @group.destroy
          account_level_group = Account.default.groups.create(name: "the account level group")
          account_level_group.add_user(@s1)
          account_level_group.add_user(@s2)
          account_level_group.save
          user_logged_in({ user: @s1 })
          get "/conversations"
          f("button[data-testid='compose']").click
          f("input[placeholder='Select Course']").click
          wait_for_ajaximations
          fj("li:contains('#{account_level_group.name}')").click
          force_click("input[data-testid='individual-message-checkbox']")
          f("input[aria-label='To']").click
          fj("li:contains('second student')").click
          f("textarea[data-testid='message-body']").send_keys "sent to everyone in the account level group"
          fj("button:contains('Send')").click
          wait_for_ajaximations
          expect(@s2.conversations.last.conversation.conversation_messages.last.body).to eq "sent to everyone in the account level group"
        end

        it "automatically sets individual message sending when max group conversation count is surpassed" do
          Setting.set("max_group_conversation_size", 3)
          @observer = user_factory(active_all: true, active_state: "active", name: "an observer")
          observer_enrollment = @course.enroll_user(@observer, "ObserverEnrollment", enrollment_state: "active")
          observer_enrollment.update_attribute(:associated_user_id, @s1.id)

          user_session(@teacher)
          get "/conversations"
          f("button[data-testid='compose']").click
          f("input[placeholder='Select Course']").click
          fj("li:contains('#{@course.name}')").click
          f("input[aria-label='To']").click
          expect(f("input[data-testid='individual-message-checkbox']")).not_to be_disabled
          fj("div[data-testid='address-book-item']:contains('Students')").click
          wait_for_ajaximations

          fj("div[data-testid='address-book-item']:contains('All in Students')").click
          expect(fj("span[data-testid='address-book-tag']:contains('All in Students')")).to be_present
          expect(f("input[data-testid='individual-message-checkbox']")).not_to be_disabled
          wait_for_ajaximations

          f("button[data-testid='include-observer-button']").click
          wait_for_ajaximations
          expect(f("input[data-testid='individual-message-checkbox']")).to be_disabled

          f("textarea[data-testid='message-body']").send_keys "sent to everyone in the account level group"
          fj("button:contains('Send')").click
          wait_for_ajaximations

          # since we are past max_group_conversation_sive, convos are created async
          expect(Conversation.count).to eq 0
          run_jobs

          # once jobs complete, 4 new Convos are created
          expect(Conversation.count).to eq 4
        end

        it "respects checkbox if it is checked, then unchecked" do
          checkbox_selector = "input[data-testid='individual-message-checkbox']"

          user_session(@teacher)
          get "/conversations"
          f("button[data-testid='compose']").click
          f("input[placeholder='Select Course']").click
          fj("li:contains('#{@course.name}')").click
          f("input[aria-label='To']").click
          expect(f("input[data-testid='individual-message-checkbox']")).not_to be_disabled
          fj("div[data-testid='address-book-item']:contains('Students')").click
          wait_for_ajaximations

          fj("div[data-testid='address-book-item']:contains('All in Students')").click
          expect(fj("span[data-testid='address-book-tag']:contains('All in Students')")).to be_present

          force_click(checkbox_selector)
          expect(f(checkbox_selector).attribute("checked")).to eq "true"

          force_click(checkbox_selector)
          expect(f(checkbox_selector).attribute("checked")).to be_nil

          f("textarea[data-testid='message-body']").send_keys "sent to everyone in the account level group"
          fj("button:contains('Send')").click
          wait_for_ajaximations

          # if count is one, then it is grouped, which is what we want
          expect(Conversation.count).to eq 1
        end
      end

      context "include observers button" do
        before do
          @observer = user_factory(active_all: true, active_state: "active", name: "an observer")
          observer_enrollment = @course.enroll_user(@observer, "ObserverEnrollment", enrollment_state: "active")
          observer_enrollment.update_attribute(:associated_user_id, @s1.id)

          @course.enroll_user(@observer, "ObserverEnrollment", section: @section2, enrollment_state: "active")
          user_session(@teacher)
          get "/conversations"
          open_react_compose_modal_addressbook
        end

        it "includes correct observers when clicked" do
          f("input[aria-label='To']").click
          fj("div[data-testid='address-book-item']:contains('All in #{@course.name}')").click
          f("button[data-testid='include-observer-button']").click
          wait_for_ajaximations

          expect(fj("span[data-testid='address-book-tag'] button:contains(#{@observer.name})")).to be_present
          expect(ff("[data-testid='address-book-tag']").count).to eq 2
        end

        it "does not include duplicate observers when clicked" do
          f("input[aria-label='To']").click
          fj("div[data-testid='address-book-item']:contains('All in #{@course.name}')").click
          f("button[data-testid='include-observer-button']").click
          wait_for_ajaximations

          expect(fj("span[data-testid='address-book-tag'] button:contains(#{@observer.name})")).to be_present
          expect(ff("[data-testid='address-book-tag']").count).to eq 2

          f("button[data-testid='include-observer-button']").click
          wait_for_ajaximations

          expect(ff("[data-testid='address-book-tag']").count).to eq 2
        end

        it "renders an alert when no observers are added" do
          f("input[aria-label='To']").click
          fj("div[data-testid='address-book-item']:contains('Students')").click
          wait_for_ajaximations
          fj("div[data-testid='address-book-item']:contains('#{@s2.name}')").click
          f("button[data-testid='include-observer-button']").click
          wait_for_ajaximations
          fj("div:contains('Selected recipient(s) do not have assigned Observers')").click

          expect(ff("[data-testid='address-book-tag']").count).to eq 1
        end
      end

      context "sent scope" do
        it "defaults to reply to recipients", :ignore_js_errors do
          conversation(@teacher, @s1, @s2, body: "hi there", workflow_state: "unread")
          user_session(@teacher)
          get "/conversations#filter=type=sent"
          f("div[data-testid='conversation']").click
          wait_for_ajaximations
          f("button[data-testid='message-reply']").click
          wait_for_ajaximations
          expect(ff("[data-testid='address-book-tag']").count).to eq 2
        end
      end

      it "clears out selected recipients when user changes the course" do
        @course1 = @course
        @course2 = course_factory(active_course: true, course_name: "Course 2")
        @course2.enroll_teacher(@teacher)
        @course3 = course_factory(active_course: true, course_name: "Course 3")
        @course3.enroll_teacher(@teacher).update_attribute(:workflow_state, "active")
        @course3.enroll_student(@s1).update_attribute(:workflow_state, "active")

        get "/conversations"

        # Select course with student
        f("button[data-testid='compose']").click
        f("input[placeholder='Select Course']").click
        fj("li:contains('#{@course3.name}')").click
        wait_for_ajaximations

        # Select student, verify that the recipient role pill is displayed
        f("input[aria-label='To']").click
        fj("div[data-testid='address-book-item']:contains('Students')").click
        wait_for_ajaximations
        fj("div[data-testid='address-book-item']:contains('#{@s1.name}')").click
        expect(fj("span[data-testid='address-book-tag']:contains('#{@s1.name}')")).to be_present

        # Change the course by clicking the course dropdown without clearing course
        f("input[placeholder='Select Course']").click
        f("input[placeholder='Select Course']").send_keys :backspace

        # Select a new course, should clear out recipients
        ffj("li:contains('#{@course2.name}')")[1].click

        # Verify that the send validations verify that there are no selected recipients
        fj("button:contains('Send')").click
        expect(ffj("span:contains('Please select a recipient')")[1]).to be_displayed
      end
    end
  end

  def assert_result_names(tf, names)
    names.each do |name|
      if tf
        expect(fj(".ac-result-container .result-name:contains(#{name})")).to be_truthy
      else
        expect(f(".ac-result-container")).not_to contain_jqcss(".result-name:contains(#{name})")
      end
    end
  end

  def assert_categories(container)
    fj(".ac-result-container .result-name:contains(#{container})").click
  end

  def goto_compose_modal
    fln("Inbox").click
    wait_for_ajaximations
    move_to_click(".icon-compose")
    wait_for_ajaximations
    f("#compose-new-message")
  end

  def open_react_compose_modal_addressbook
    # Open compose modal
    f("button[data-testid='compose']").click

    # select the only course option
    f("input[placeholder='Select Course']").click
    f("li[role='none']").click

    # Open address book
    f("input[aria-label='To']").click
  end
end
