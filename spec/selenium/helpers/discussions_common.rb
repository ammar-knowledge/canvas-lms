# frozen_string_literal: true

#
# Copyright (C) 2012 - present Instructure, Inc.
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

require_relative "../common"

module DiscussionsCommon
  def go_to_topic
    get "/courses/#{@course.id}/discussion_topics/#{@topic.id}"
  end

  def create_and_go_to_topic(title = "new topic", discussion_type = "side_comment", is_locked = false)
    @topic = @course.discussion_topics.create!(title:, discussion_type:)
    if is_locked
      @topic.lock
      @topic.reload
    end
    go_to_topic
    @topic
  end

  def create_discussion(discussion_name, discussion_type)
    @course.discussion_topics.create!(title: discussion_name, discussion_type:, message: "Discussion topic message")
  end

  def create_graded_discussion(discussion_course, assignment_options = {})
    default_assignment_options = {
      name: "Default Assignment",
      points_possible: 10,
      assignment_group: discussion_course.assignment_groups.create!(name: "Default Assignment Group"),
      only_visible_to_overrides: false
    }
    options = default_assignment_options.merge(assignment_options)

    discussion_assignment = discussion_course.assignments.create!(options)
    all_graded_discussion_options = {
      title: "assignment topic title",
      message: "assignment topic message",
      discussion_type: "threaded",
      assignment: discussion_assignment,
    }
    discussion_course.discussion_topics.create!(all_graded_discussion_options)
  end

  def generate_expected_overrides(assignment)
    expected_overrides = []

    if assignment.assignment_overrides.active.empty?
      expected_overrides << ["Everyone"]
    else
      unless assignment.only_visible_to_overrides
        expected_overrides << ["Everyone else"]
      end

      assignment.assignment_overrides.active.each do |override|
        if override.set_type == "CourseSection"
          expected_overrides << [override.title]
        elsif override.set_type == "ADHOC"
          student_names = override.assignment_override_students.map { |student| student.user.name }
          expected_overrides << student_names
        end
      end
    end

    expected_overrides
  end

  def edit_topic(discussion_name, message)
    wait_for_rce
    replace_content(f("input[name=title]"), discussion_name)
    type_in_tiny("textarea[name=message]", message)
    expect_new_page_load { submit_form(".form-actions") }
    expect(f('[data-testid="message_title"]')).to include_text(discussion_name)
  end

  def edit_entry(entry, text)
    wait_for_ajaximations
    click_entry_option(entry, ".discussion-thread-menuitem-edit")
    wait_for_ajaximations
    type_in_tiny "textarea", text
    f('[data-testid="DiscussionEdit-submit"]').click
    wait_for_ajaximations
    validate_entry_text(entry, text)
  end

  def check_edit_entry(entry)
    wait_for_ajaximations
    check_entry_option(entry, ".al-options:visible li:eq(1) a")
  end

  def delete_entry(entry)
    wait_for_ajaximations
    click_entry_option(entry, ".al-options:visible li:last-child a")
    driver.switch_to.alert.accept
    wait_for_ajax_requests
    entry.reload
    expect(entry.workflow_state).to eq "deleted"
  end

  def check_delete_entry(entry)
    wait_for_ajaximations
    check_entry_option(entry, ".al-options:visible li:eq(2) a")
  end

  def add_reply(message = "message!", attachment = nil)
    @last_entry ||= f('[data-testid="discussion-topic-container"]')
    @last_entry.find_element(:css, '[data-testid="discussion-topic-reply"]').click
    wait_for_ajaximations
    type_in_tiny "textarea", message

    if attachment.present?
      _filename, fullpath, _data = get_file(attachment)
      scroll_to(@last_entry.find_element(:css, '[data-testid="attach-btn"]'))
      @last_entry.find_element(:css, '[data-testid="attach-btn"]').click
      wait_for_ajaximations
      @last_entry.find_element(:css, '[data-testid="attachment-input"]').send_keys(fullpath)
    end
    f('[data-testid="DiscussionEdit-submit"]').click
    wait_for(method: nil, timeout: 5) { f('[data-testid="discussion-entry-container"]').displayed? }
    id = DiscussionEntry.last.id
    @last_entry = f("[data-entry-id='#{id}']")
  end

  def get_all_replies
    ff('[data-testid="discussion-entry-container"]')
  end

  def validate_entry_text(discussion_entry, text)
    expect(f("[data-entry-id='#{discussion_entry.id}']").text).to include(text)
  end

  def check_entry_option(discussion_entry, menu_item_selector)
    li_selector = "#entry-#{discussion_entry.id}"
    expect(fj(li_selector)).to be_displayed
    expect(fj("#{li_selector} .al-trigger")).to be_displayed
    fj("#{li_selector} .al-trigger").click
    wait_for_ajaximations
    expect(f("body")).not_to contain_jqcss(menu_item_selector)
  end

  def click_entry_option(discussion_entry, menu_item_selector)
    entry_selector = "[data-entry-id='#{discussion_entry.id}']"
    wait_for(method: nil, timeout: 2) { f(entry_selector).displayed? }
    menu_button = f(entry_selector.to_s + ' [data-testid="thread-actions-menu"]')
    scroll_to(menu_button)
    menu_button.click
    wait_for_ajaximations
    f(menu_item_selector).click
  end

  def click_topic_option(topic_selector, menu_item_selector)
    topic = f(topic_selector)
    topic.find_element(:css, ".al-trigger").click
    fj(menu_item_selector).click
    topic
  end

  def set_checkbox(selector, check)
    cb = fj("#" + selector + (check ? ":not(:checked)" : ":checked"))
    if cb
      f("label[for=#{selector}]").click # have to click on the label because the input isn't visible
    end
  end

  def filter(opts)
    replace_content(f("#searchTerm"), opts[:term] || "")
    wait_for_ajaximations
    f("#searchTerm").send_keys(:return)
    # logic for dealing with options
    case opts
    when { only_graded: true }
      set_checkbox("onlyGraded", opts[:only_graded])
    when { only_unread: true }
      set_checkbox("onlyUnread", opts[:only_unread])
    when { only_unread: true, only_graded: true }
      set_checkbox("onlyGraded", opts[:only_graded])
      set_checkbox("onlyUnread", opts[:only_unread])
    end
    wait_for_animations
  end

  def index_is_showing?(*topics)
    ffj(".discussion-list li.discussion:visible").count == topics.size &&
      topics.all? { |t| topic_index_element(t).try(:displayed?) }
  end

  def add_attachment_and_validate
    filename, fullpath, _data = get_file("testfile5.zip")
    f("input[name=attachment]").send_keys(fullpath)
    type_in_tiny("textarea[name=message]", "file attachment discussion")
    yield if block_given?
    expect_new_page_load { submit_form(".form-actions") }
    wait_for_ajaximations
    expect(fxpath('//a[contains(text(), ".zip")]')).to include_text(filename)
  end

  def edit(title, message)
    replace_content(f("input[name=title]"), title)
    type_in_tiny("textarea[name=message]", message)
    expect_new_page_load { submit_form(".form-actions") }
    expect(f('[data-testid="message_title"]')).to include_text(title)
  end

  def topic_index_element(topic)
    fj(".discussion[data-id='#{topic.id}']")
  end

  def check_permissions(number_of_checkboxes = 1)
    get url
    wait_for_ajaximations
    if number_of_checkboxes > 0
      checkboxes = ff(".discussion .al-trigger")
      expect(checkboxes.length).to eq number_of_checkboxes
    else
      expect(f("#content")).not_to contain_css(".discussion .al-trigger")
    end
    expect(ff(".discussion-list li.discussion").length).to eq DiscussionTopic.count
  end

  def topic_for_filtering(opts = {})
    name = "#{opts[:graded] ? "graded" : "ungraded"} #{opts[:read] ? "read" : "unread"} topic"
    if opts[:graded]
      a = course.assignments.create!(name: name + " assignment", submission_types: "discussion_topic", assignment_group:)
      dt = a.discussion_topic
      dt.title = name + " title"
      dt.save!
    else
      dt = course.discussion_topics.create!(user: student, title: name + " title", message: name + " message")
    end
    dt.change_read_state(opts[:read] ? "read" : "unread", somebody)
    dt
  end

  def click_publish_icon(topic)
    get url
    fj(".discussion[data-id=#{topic.id}] .publish-icon i").click
    wait_for_ajaximations
  end

  def confirm(state)
    checkbox_state = (state == :on) ? "true" : nil
    get url
    wait_for_ajaximations

    expect(f("input[type=checkbox][name=threaded]")[:checked]).to eq checkbox_state
    expect(f("input[type=checkbox][name=require_initial_post]")[:checked]).to eq checkbox_state
    expect(f("input[type=checkbox][name=podcast_enabled]")[:checked]).to eq checkbox_state
    expect(f("input[type=checkbox][name=podcast_has_student_posts]")[:checked]).to eq checkbox_state
    expect(f('input[type=checkbox][name="assignment[set_assignment]"]')[:checked]).to eq checkbox_state
  end

  def toggle(state)
    f("input[type=checkbox][name=threaded]").click
    set_value f("input[name=delayed_post_at]"), 2.weeks.from_now.strftime("%m/%d/%Y") if state == :on
    f("input[type=checkbox][name=require_initial_post]").click
    f("input[type=checkbox][name=podcast_enabled]").click
    f("input[type=checkbox][name=podcast_has_student_posts]").click if state == :on
    f('input[type=checkbox][name="assignment[set_assignment]"]').click

    expect_new_page_load { f(".form-actions button[type=submit]").click }
    wait_for_ajaximations
  end

  def wait_for_subscription_icon_to_load(expected_class)
    expect(f(".subscription-toggler")).to be
    driver.execute_script(%{$('.subscription-toggler').trigger('mouseleave')})
    expect(f(".subscription-toggler")).to have_class(expected_class)
  end
end
