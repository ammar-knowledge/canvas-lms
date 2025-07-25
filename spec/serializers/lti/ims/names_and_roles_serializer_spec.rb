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

describe Lti::IMS::NamesAndRolesSerializer do
  include Lti::IMS::NamesAndRolesMatchers

  subject { described_class.new(page) }

  let_once(:course) { course_factory(active_course: true) }
  let(:result) { raise "Override in context" }
  let(:url) { "http://test.test/results" }
  let(:page) { raise "Override in context" }
  let(:privacy_level) { "public" }
  let(:tool) do
    ContextExternalTool.create!(
      context: course,
      consumer_key: "key",
      shared_secret: "secret",
      name: "test tool",
      url: "http://www.tool.com/launch",
      lti_version: "1.3",
      workflow_state: privacy_level
    )
  end
  let(:message_matcher) { {} }

  def serialize
    subject.as_json.with_indifferent_access
  end

  def be_lti_membership_context
    return be_lti_course_membership_context(decorated_course) if context_type == :course

    be_lti_group_membership_context(decorated_group)
  end

  def be_lti_membership
    matcher_opts = {
      privacy_level:
    }
    if page[:opts].present? && page[:opts][:rlid].present?
      matcher_opts[:message_matcher] = message_matcher
    end

    if context_type == :course
      be_lti_course_membership(matcher_opts.merge!(expected: [decorated_enrollment]))
    else
      be_lti_group_membership(matcher_opts.merge!(expected: decorated_group_member))
    end
  end

  def create_pseudonym!(user)
    user.pseudonyms.create!({
                              account: course.account,
                              unique_id: "user1@example.com",
                              password: "asdfasdf",
                              password_confirmation: "asdfasdf",
                              workflow_state: "active",
                              sis_user_id: "user-1-sis-user-id-1"
                            })
  end

  shared_context "course and tool for variable substitution" do
    let(:course) do
      course = super()
      course.name = "Brand new course"
      course.start_at = 3.days.ago
      course.conclude_at = 1.day.ago
      course.grade_passback_setting = "nightly_sync"
      course.save!
      course
    end

    let(:tool) do
      tool = super()
      tool.settings[:custom_fields] = {
        canvas_course_endAt: "$Canvas.course.endAt",
        canvas_course_gradePassbackSetting: "$Canvas.course.gradePassbackSetting",
        canvas_course_hideDistributionGraphs: "$Canvas.course.hideDistributionGraphs",
        canvas_course_id: "$Canvas.course.id",
        canvas_course_name: "$Canvas.course.name",
        canvas_course_previousContextIds: "$Canvas.course.previousContextIds",
        canvas_course_previousContextIds_recursive: "$Canvas.course.previousContextIds.recursive",
        canvas_course_previousCourseIds: "$Canvas.course.previousCourseIds",
        canvas_course_sectionIds: "$Canvas.course.sectionIds",
        canvas_course_sectionRestricted: "$Canvas.course.sectionRestricted",
        canvas_course_sectionSisSourceIds: "$Canvas.course.sectionSisSourceIds",
        canvas_course_sisSourceId: "$Canvas.course.sisSourceId",
        canvas_course_startAt: "$Canvas.course.startAt",
        canvas_course_workflowState: "$Canvas.course.workflowState"
      }
      tool.save!
      tool
    end

    let(:page) do
      super().merge(opts: { rlid: "rlid-value" })
    end
  end

  shared_examples "enrollment serialization" do
    it "properly formats NRPS json" do
      json = serialize
      expect(json[:id]).to eq url
      expect(json[:context]).to be_lti_membership_context
      expect(json[:members][0]).to be_lti_membership
    end

    context "with past lti ids" do
      before do
        UserPastLtiId.create!(user:, context: course, user_lti_id: "current_lti_key", user_lti_context_id: "old_lti_id", user_uuid: "old")
      end

      it "properly formats NRPS json" do
        json = serialize
        expect(json[:members][0][:user_id]).to eq "current_lti_key"
      end
    end
  end

  shared_examples "serializes message array if rlid param present" do
    let(:tool) do
      tool = super()
      tool.settings[:custom_fields] = {
        user_id: "$User.id",
        canvas_user_id: "$Canvas.user.id",
        unsupported_param_1: "$unsupported.param.1",
        unsupported_param_2: "$unsupported.param.2"
      }
      tool.save!
      tool
    end
    let(:resource_link) do
      Lti::ResourceLink.create!(
        context: course,
        context_external_tool: tool,
        url: "https://www.example.com/launch/resource_link",
        custom: custom_params
      )
    end
    let(:custom_params) { { foo: "bar" } }
    let(:page) do
      super().merge(opts: { rlid: resource_link.resource_link_uuid })
    end
    let(:message_matcher) do
      {
        "https://purl.imsglobal.org/spec/lti/claim/custom" => {
          "user_id" => user.id.to_s,
          "canvas_user_id" => user.id.to_s,
          "unsupported_param_1" => "$unsupported.param.1",
          "unsupported_param_2" => "$unsupported.param.2"
        }.merge(custom_params)
      }
    end

    it_behaves_like "enrollment serialization", true
  end

  # Technically all these '...privacy policy' examples are redundant w/r/t be_lti_*_membership(). But those matchers
  # basically just echo logic from the serializer, so we want this additional set of declarative expectations to
  # confirm that the logic is actually right.
  shared_examples "public privacy policy" do
    it "properly formats NRPS json" do
      json = serialize
      expect(json[:id]).to eq url
      expect(json[:context]).to be_lti_membership_context
      expect(json[:members][0]).to include(:status, :name, :picture, :given_name, :family_name, :email, :lis_person_sourcedid, :user_id, :roles)
    end
  end

  shared_examples "anonymous privacy policy" do
    it "properly formats NRPS json" do
      json = serialize
      expect(json[:id]).to eq url
      expect(json[:context]).to be_lti_membership_context
      expect(json[:members][0]).to include(:status, :user_id, :roles)
      expect(json[:members][0]).not_to include(:name, :picture, :given_name, :family_name, :email, :lis_person_sourcedid)
    end
  end

  shared_examples "name_only privacy policy" do
    it "properly formats NRPS json" do
      json = serialize
      expect(json[:id]).to eq url
      expect(json[:context]).to be_lti_membership_context
      expect(json[:members][0]).to include(:status, :name, :given_name, :family_name, :lis_person_sourcedid, :user_id, :roles)
      expect(json[:members][0]).not_to include(:picture, :email)
    end
  end

  shared_examples "email_only privacy policy" do
    it "properly formats NRPS json" do
      json = serialize
      expect(json[:id]).to eq url
      expect(json[:context]).to be_lti_membership_context
      expect(json[:members][0]).to include(:status, :email, :user_id, :roles)
      expect(json[:members][0]).not_to include(:name, :picture, :given_name, :family_name, :lis_person_sourcedid)
    end
  end

  describe "#as_json" do
    context "with a course" do
      let(:context_type) { :course }
      let(:enrollment) do
        enrollment = teacher_in_course(course:, active_all: true, name: "Marta Perkins")
        user = enrollment.user
        user.email = "marta.perkins@school.edu"
        user.avatar_image_url = "http://school.edu/image/url.png"
        user.save!
        create_pseudonym!(user)
        enrollment
      end
      let(:user) { enrollment.user }
      let(:decorated_enrollment) do
        Lti::IMS::Providers::CourseMembershipsProvider::CourseEnrollmentsDecorator.new([enrollment], tool)
      end
      let(:decorated_course) { Lti::IMS::Providers::CourseMembershipsProvider::CourseContextDecorator.new(course) }
      let(:page) do
        {
          url:,
          memberships: [decorated_enrollment],
          context: decorated_course,
          assignment: nil,
          api_metadata: nil,
          controller: nil,
          tool:,
          opts: {}
        }
      end

      context "and a public tool" do
        it_behaves_like "enrollment serialization"
        it_behaves_like "public privacy policy"
      end

      context "and an anonymous tool" do
        let(:privacy_level) { "anonymous" }

        it_behaves_like "enrollment serialization"
        it_behaves_like "anonymous privacy policy"
      end

      context "and a name_only tool" do
        let(:privacy_level) { "name_only" }

        it_behaves_like "enrollment serialization"
        it_behaves_like "name_only privacy policy"
      end

      context "and an email_only tool" do
        let(:privacy_level) { "email_only" }

        it_behaves_like "enrollment serialization"
        it_behaves_like "email_only privacy policy"
      end

      it_behaves_like "serializes message array if rlid param present"

      context "variables expansion" do
        include_context "course and tool for variable substitution"

        context "with disallow_null_custom_variables feature flag enabled" do
          before do
            Account.site_admin.disable_feature!(:custom_variables_booleans_as_strings)
          end

          it "expand course-related variables from the tool settings" do
            json = serialize

            received_custom_claim = json[:members][0][:message].first["https://purl.imsglobal.org/spec/lti/claim/custom"]
            expect(received_custom_claim["canvas_course_endat"]).to eq course.end_at.utc.iso8601
            expect(received_custom_claim["canvas_course_gradepassbacksetting"]).to eq course.grade_passback_setting
            expect(received_custom_claim["canvas_course_hidedistributiongraphs"]).to eq course.hide_distribution_graphs?
            expect(received_custom_claim["canvas_course_id"]).to eq course.id.to_s
            expect(received_custom_claim["canvas_course_name"]).to eq course.name

            lti_helper = Lti::SubstitutionsHelper.new(course, course.root_account, user, tool)
            expect(received_custom_claim["canvas_course_previouscontextids"]).to eq lti_helper.previous_lti_context_ids
            expect(received_custom_claim["canvas_course_previouscontextids_recursive"]).to eq lti_helper.recursively_fetch_previous_lti_context_ids
            expect(received_custom_claim["canvas_course_previouscourseids"]).to eq lti_helper.previous_course_ids
            expect(received_custom_claim["canvas_course_sectionids"]).to eq lti_helper.section_ids
            expect(received_custom_claim["canvas_course_sectionrestricted"]).to eq lti_helper.section_restricted
            expect(received_custom_claim["canvas_course_sectionsissourceids"]).to eq lti_helper.section_sis_ids

            expect(received_custom_claim["canvas_course_sissourceid"]).to eq "$Canvas.course.sisSourceId"
            expect(received_custom_claim["canvas_course_startat"]).to eq course.start_at.utc.iso8601
            expect(received_custom_claim["canvas_course_workflowstate"]).to eq course.workflow_state
          end
        end

        context "with disallow_null_custom_variables feature flag disabled" do
          before do
            Account.site_admin.disable_feature!(:disallow_null_custom_variables)
            Account.site_admin.disable_feature!(:custom_variables_booleans_as_strings)
          end

          it "expand course-related variables from the tool settings" do
            json = serialize
            received_custom_claim = json[:members][0][:message].first["https://purl.imsglobal.org/spec/lti/claim/custom"]

            expect(received_custom_claim["canvas_course_endat"]).to eq course.end_at.utc.iso8601
            expect(received_custom_claim["canvas_course_gradepassbacksetting"]).to eq course.grade_passback_setting
            expect(received_custom_claim["canvas_course_hidedistributiongraphs"]).to eq course.hide_distribution_graphs?
            expect(received_custom_claim["canvas_course_id"]).to eq course.id.to_s
            expect(received_custom_claim["canvas_course_name"]).to eq course.name

            lti_helper = Lti::SubstitutionsHelper.new(course, course.root_account, user, tool)
            expect(received_custom_claim["canvas_course_previouscontextids"]).to eq lti_helper.previous_lti_context_ids
            expect(received_custom_claim["canvas_course_previouscontextids_recursive"]).to eq lti_helper.recursively_fetch_previous_lti_context_ids
            expect(received_custom_claim["canvas_course_previouscourseids"]).to eq lti_helper.previous_course_ids
            expect(received_custom_claim["canvas_course_sectionids"]).to eq lti_helper.section_ids
            expect(received_custom_claim["canvas_course_sectionrestricted"]).to eq lti_helper.section_restricted
            expect(received_custom_claim["canvas_course_sectionsissourceids"]).to eq lti_helper.section_sis_ids

            expect(received_custom_claim["canvas_course_sissourceid"]).to eq course.sis_source_id
            expect(received_custom_claim["canvas_course_startat"]).to eq course.start_at.utc.iso8601
            expect(received_custom_claim["canvas_course_workflowstate"]).to eq course.workflow_state
          end
        end
      end
    end

    context "with a account-based group" do
      let(:context_type) { :group }
      let(:group_record) { group_with_user(context: course.account, active_all: true, name: "Marta Perkins").group }
      let(:group_member) do
        enrollment = group_record.group_memberships.first
        user = enrollment.user
        user.email = "marta.perkins@school.edu"
        user.avatar_image_url = "http://school.edu/image/url.png"
        user.save!
        create_pseudonym!(user)
        enrollment
      end
      let(:user) { group_member.user }
      let(:decorated_group_member) do
        Lti::IMS::Providers::GroupMembershipsProvider::GroupMembershipDecorator.new(group_member, tool)
      end
      let(:decorated_group) { Lti::IMS::Providers::GroupMembershipsProvider::GroupContextDecorator.new(group_record) }
      let(:page) do
        {
          url:,
          memberships: [decorated_group_member],
          context: decorated_group,
          assignment: nil,
          api_metadata: nil,
          controller: nil,
          tool:,
          opts: {}
        }
      end

      context "and a public tool" do
        it_behaves_like "enrollment serialization"
        it_behaves_like "public privacy policy"
      end

      context "and an anonymous tool" do
        let(:privacy_level) { "anonymous" }

        it_behaves_like "enrollment serialization"
        it_behaves_like "anonymous privacy policy"
      end

      context "and a name_only tool" do
        let(:privacy_level) { "name_only" }

        it_behaves_like "enrollment serialization"
        it_behaves_like "name_only privacy policy"
      end

      context "and an email_only tool" do
        let(:privacy_level) { "email_only" }

        it_behaves_like "enrollment serialization"
        it_behaves_like "email_only privacy policy"
      end

      it_behaves_like "serializes message array if rlid param present"

      context "variables expansion" do
        include_context "course and tool for variable substitution"

        it "does not expand course-related variables from the tool settings" do
          # the variable expander needs the Course as a @context
          json = serialize
          received_custom_claim = json[:members][0][:message].first["https://purl.imsglobal.org/spec/lti/claim/custom"]

          expect(received_custom_claim["canvas_course_endat"]).to eq "$Canvas.course.endAt"
          expect(received_custom_claim["canvas_course_gradepassbacksetting"]).to eq "$Canvas.course.gradePassbackSetting"
          expect(received_custom_claim["canvas_course_hidedistributiongraphs"]).to eq "$Canvas.course.hideDistributionGraphs"
          expect(received_custom_claim["canvas_course_id"]).to eq "$Canvas.course.id"
          expect(received_custom_claim["canvas_course_name"]).to eq "$Canvas.course.name"
          expect(received_custom_claim["canvas_course_previouscontextids"]).to eq "$Canvas.course.previousContextIds"
          expect(received_custom_claim["canvas_course_previouscontextids_recursive"]).to eq "$Canvas.course.previousContextIds.recursive"
          expect(received_custom_claim["canvas_course_previouscourseids"]).to eq "$Canvas.course.previousCourseIds"
          expect(received_custom_claim["canvas_course_sectionids"]).to eq "$Canvas.course.sectionIds"
          expect(received_custom_claim["canvas_course_sectionrestricted"]).to eq "$Canvas.course.sectionRestricted"
          expect(received_custom_claim["canvas_course_sectionsissourceids"]).to eq "$Canvas.course.sectionSisSourceIds"
          expect(received_custom_claim["canvas_course_sissourceid"]).to eq "$Canvas.course.sisSourceId"
          expect(received_custom_claim["canvas_course_startat"]).to eq "$Canvas.course.startAt"
          expect(received_custom_claim["canvas_course_workflowstate"]).to eq "$Canvas.course.workflowState"
        end
      end
    end
  end
end
