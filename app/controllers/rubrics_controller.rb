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

# @API Rubrics
class RubricsController < ApplicationController
  before_action :require_context

  include HorizonMode
  before_action :load_canvas_career, only: [:index, :show]

  before_action { |c| c.active_tab = "rubrics" }

  include Api::V1::Outcome
  include Api::V1::Progress
  include K5Mode

  def index
    permission = @context.is_a?(User) ? :manage : [:manage_rubrics, :read_rubrics]
    return unless authorized_action(@context, @current_user, permission)

    if @context.is_a?(Course) && @context.horizon_course?
      redirect_to named_context_url(@context, :context_context_modules_url)
      return
    end

    js_env ROOT_OUTCOME_GROUP: get_root_outcome,
           PERMISSIONS: {
             manage_outcomes: @context.grants_right?(@current_user, session, :manage_outcomes),
             manage_rubrics: @context.grants_right?(@current_user, session, :manage_rubrics)
           },
           NON_SCORING_RUBRICS: @domain_root_account.feature_enabled?(:non_scoring_rubrics),
           OUTCOMES_NEW_DECAYING_AVERAGE_CALCULATION: @domain_root_account.feature_enabled?(:outcomes_new_decaying_average_calculation)

    mastery_scales_js_env
    set_tutorial_js_env

    if @context.feature_enabled?(:enhanced_rubrics)
      js_env breadcrumbs: rubric_breadcrumbs
      js_env enhanced_rubrics_enabled: true
      js_env rubric_imports_exports: Account.site_admin.feature_enabled?(:rubric_imports_exports)
      js_env enhanced_rubrics_copy_to: Account.site_admin.feature_enabled?(:enhanced_rubrics_copy_to)
      js_env enhanced_rubric_assignments_enabled: Rubric.enhanced_rubrics_assignments_enabled?(@context)

      return show_rubrics_redesign
    end

    @rubric_associations = @context.rubric_associations.bookmarked.include_rubric.to_a
    @rubric_associations = Canvas::ICU.collate_by(@rubric_associations.select(&:rubric_id).uniq(&:rubric_id)) { |r| r.rubric.title }
    @rubrics = @rubric_associations.map(&:rubric)
    @context.is_a?(User) ? render(action: "user_index") : render
  end

  def show
    permission = @context.is_a?(User) ? :manage : [:manage_rubrics, :read_rubrics]
    return unless authorized_action(@context, @current_user, permission)

    is_enhanced_rubrics = @context.feature_enabled?(:enhanced_rubrics)

    if params[:id].match?(Api::ID_REGEX) || is_enhanced_rubrics
      js_env ROOT_OUTCOME_GROUP: get_root_outcome,
             PERMISSIONS: {
               manage_rubrics: @context.grants_right?(@current_user, session, :manage_rubrics)
             },
             OUTCOMES_NEW_DECAYING_AVERAGE_CALCULATION: @domain_root_account.feature_enabled?(:outcomes_new_decaying_average_calculation)
      mastery_scales_js_env

      if is_enhanced_rubrics
        js_env breadcrumbs: rubric_breadcrumbs
        js_env enhanced_rubrics_enabled: true
        js_env enhanced_rubric_assignments_enabled: Rubric.enhanced_rubrics_assignments_enabled?(@context)

        return show_rubrics_redesign
      end

      @rubric_association = @context.rubric_associations.bookmarked.find_by(rubric_id: params[:id])
      raise ActiveRecord::RecordNotFound unless @rubric_association

      @actual_rubric = @rubric_association.rubric
    else
      raise ActiveRecord::RecordNotFound
    end
  end

  def show_rubrics_redesign
    css_bundle :enhanced_rubrics
    render html: "".html_safe, layout: true
  end

  def rubric_breadcrumbs
    breadcrumbs = crumbs[1..]&.map { |crumb| { name: crumb[0], url: crumb[1] } }
    breadcrumbs << { name: t("Rubrics"), url: context_url(@context, :context_rubrics_url) }
  end

  # @API Create a single rubric
  #
  # Returns the rubric with the given id.
  #
  # Unfortuantely this endpoint does not return a standard Rubric object,
  # instead it returns a hash that looks like
  #   { 'rubric': Rubric, 'rubric_association': RubricAssociation }
  #
  # This may eventually be deprecated in favor of a more standardized return
  # value, but that is not currently planned.
  #
  # @argument id [Integer]
  #   The id of the rubric
  # @argument rubric_association_id [Integer]
  #   The id of the rubric association object (not the course/assignment itself, but the join table record id).
  #   It can be used in place of +rubric_association[association_id]+ and +rubric_association[association_type]+ if desired.
  # @argument rubric[title] [String]
  #   The title of the rubric
  # @argument rubric[free_form_criterion_comments] [Boolean]
  #   Whether or not you can write custom comments in the ratings field for a rubric
  # @argument rubric_association[association_id] [Integer]
  #   The id of the object with which this rubric is associated
  # @argument rubric_association[association_type] ["Assignment"|"Course"|"Account"]
  #   The type of object this rubric is associated with
  # @argument rubric_association[use_for_grading] [Boolean]
  #   Whether or not the associated rubric is used for grade calculation
  # @argument rubric_association[hide_score_total] [Boolean]
  #   Whether or not the score total is displayed within the rubric.
  #   This option is only available if the rubric is not used for grading.
  # @argument rubric_association[purpose] [String]
  #   Whether or not the association is for grading (and thus linked to an assignment)
  #   or if it's to indicate the rubric should appear in its context
  # @argument rubric[criteria] [Hash]
  #   An indexed Hash of RubricCriteria objects where the keys are integer ids and the values are the RubricCriteria objects
  def create
    update
  end

  # This controller looks yucky (and is yucky) because it handles a funky logic.
  # If you try to update a rubric that is being used in more than one place,
  # instead of updating that rubric this will create a new rubric based on
  # the old rubric and return that one instead.  If you pass it a rubric_association_id
  # parameter, then it will point the rubric_association to the new rubric
  # instead of the old one.

  # @API Update a single rubric
  #
  # Returns the rubric with the given id.
  #
  # Unfortuantely this endpoint does not return a standard Rubric object,
  # instead it returns a hash that looks like
  #   { 'rubric': Rubric, 'rubric_association': RubricAssociation }
  #
  # This may eventually be deprecated in favor of a more standardized return
  # value, but that is not currently planned.
  #
  # @argument id [Integer]
  #   The id of the rubric
  # @argument rubric_association_id [Integer]
  #   The id of the rubric association object (not the course/assignment itself, but the join table record id).
  #   It can be used in place of +rubric_association[association_id]+ and +rubric_association[association_type]+ if desired.
  # @argument rubric[title] [String]
  #   The title of the rubric
  # @argument rubric[free_form_criterion_comments] [Boolean]
  #   Whether or not you can write custom comments in the ratings field for a rubric
  # @argument rubric[skip_updating_points_possible] [Boolean]
  #   Whether or not to update the points possible
  # @argument rubric_association[association_id] [Integer]
  #   The id of the object with which this rubric is associated
  # @argument rubric_association[association_type] ["Assignment"|"Course"|"Account"]
  #   The type of object this rubric is associated with
  # @argument rubric_association[use_for_grading] [Boolean]
  #   Whether or not the associated rubric is used for grade calculation
  # @argument rubric_association[hide_score_total] [Boolean]
  #   Whether or not the score total is displayed within the rubric.
  #   This option is only available if the rubric is not used for grading.
  # @argument rubric_association[purpose] ["grading"|"bookmark"]
  #   Whether or not the association is for grading (and thus linked to an assignment)
  #   or if it's to indicate the rubric should appear in its context
  # @argument rubric[criteria] [Hash]
  #   An indexed Hash of RubricCriteria objects where the keys are integer ids and the values are the RubricCriteria objects
  def update
    association_params = if params[:rubric_association]
                           params[:rubric_association].permit(:use_for_grading, :title, :purpose, :url, :hide_score_total, :hide_points, :hide_outcome_results, :bookmarked)
                         else
                           {}
                         end

    @association_object = RubricAssociation.get_association_object(params[:rubric_association])
    params[:rubric][:user] = @current_user if params[:rubric]
    if can_manage_rubrics_or_association_object?(@association_object)
      @association = @context.rubric_associations.where(id: params[:rubric_association_id]).first if params[:rubric_association_id].present?
      @association_object ||= @association.association_object if @association
      association_params[:association_object] = @association_object
      association_params[:update_if_existing] = params[:action] == "update"
      skip_points_update = !!(params[:skip_updating_points_possible] =~ /true/i)
      association_params[:skip_updating_points_possible] = skip_points_update
      @rubric = @association.rubric if params[:id] && (@association&.rubric_id == params[:id].to_i || (@association&.rubric && @association.rubric.migration_id == "cloned_from_#{params[:id]}"))
      @rubric ||= @context.rubrics.where(id: params[:id]).first if params[:id].present?
      @association = nil unless @association && @rubric && @association.rubric_id == @rubric.id
      association_params[:id] = @association.id if @association
      # Update the rubric if you can
      # Better specify params[:rubric_association_id] if you want it to update an existing association

      # If this is a brand new rubric OR if the rubric isn't editable OR if the rubric context is different than the context,
      # then create a new rubric
      if !@rubric || (
        @rubric.will_change_with_update?(params[:rubric]) && (
          !@rubric.grants_right?(@current_user, session, :update) || (
            @rubric.context.is_a?(Account) && @rubric.context != @context
          )
        )
      )
        original_rubric_id = @rubric&.id
        @rubric = @context.rubrics.build
        @rubric.rubric_id = original_rubric_id
        @rubric.user = @current_user
      end
      if params[:rubric] && (@rubric.grants_right?(@current_user, session, :update) || @association&.grants_right?(@current_user, session, :update)) # authorized_action(@rubric, @current_user, :update)
        @association = @rubric.update_with_association(@current_user, params[:rubric], @context, association_params)

        return render json: { error: true, messages: @association.errors.to_a } unless @association.nil? || @association.valid?

        @rubric = @association.rubric if @association
      end
      @rubric.reconcile_criteria_models(@current_user)
      track_metrics
      json_res = {}
      json_res[:rubric] = @rubric.as_json(methods: :criteria, include_root: false, permissions: { user: @current_user, session: }) if @rubric
      json_res[:rubric_association] = @association.as_json(include_root: false, include: [:assessment_requests], permissions: { user: @current_user, session: }) if @association
      json_res[:rubric_association][:skip_updating_points_possible] = skip_points_update if json_res && json_res[:rubric_association]
      render json: json_res
    end
  end

  ALLOWED_GENERATE_PARAMS = %w[criteria_count rating_count points_per_criterion use_range additional_prompt_info grade_level].freeze
  def llm_criteria
    association_object = RubricAssociation.get_association_object(params[:rubric_association])
    generate_options = (params[:generate_options] || {}).permit(*ALLOWED_GENERATE_PARAMS)
    generate_options[:use_range] = value_to_boolean(generate_options[:use_range])
    generate_options[:additional_prompt_info] = generate_options[:additional_prompt_info].presence
    if generate_options[:criteria_count].present? && !(2..8).cover?(generate_options[:criteria_count].to_i)
      return render json: { error: "criteria_count must be between 2 and 8 inclusive" }, status: :bad_request
    end
    if generate_options[:rating_count].present? && !(2..8).cover?(generate_options[:rating_count].to_i)
      return render json: { error: "rating_count must be between 2 and 8 inclusive" }, status: :bad_request
    end
    if generate_options[:additional_prompt_info].present? && generate_options[:additional_prompt_info].length > 1000
      return render json: { error: "additional_prompt_info must be less than 1000 characters" }, status: :bad_request
    end

    return render_unauthorized_action unless Rubric.ai_rubrics_enabled?(context)

    @rubric = @context.rubrics.build(user: @current_user)
    if can_manage_rubrics_or_association_object?(association_object) && authorized_action(@rubric, @current_user, :update)
      progress = Progress.create!(context: association_object, user: @current_user, tag: "llm_rubric_generation")
      progress.process_job(
        Rubric,
        :process_generate_criteria_via_llm,
        {
          priority: Delayed::NORMAL_PRIORITY,
          n_strand: ["Rubric.process_generate_criteria_via_llm", @domain_root_account.global_id],
          max_attempts: 3,
        },
        @context,
        @current_user,
        association_object,
        generate_options.to_h
      )

      render json: progress_json(progress, @current_user, session)
    end
  end

  # @API Delete a single
  #
  # Deletes a Rubric and removes all RubricAssociations.
  #
  # @returns Rubric
  def destroy
    @rubric = RubricAssociation.active.where(rubric_id: params[:id], context_id: @context, context_type: @context.class.to_s).first.rubric
    if authorized_action(@rubric, @current_user, :delete_associations) && authorized_action(@context, @current_user, :manage_rubrics)
      @rubric.destroy_for(@context, current_user: @current_user)
      render json: @rubric
    end
  end

  # Internal: Find and format the given context's root outcome group.
  #
  # Returns a JSON outcome object or nil.
  def get_root_outcome
    root_outcome = if @context.respond_to?(:root_outcome_group)
                     @context.root_outcome_group
                   elsif @context.respond_to?(:account)
                     @context.account.root_outcome_group
                   end

    return nil if root_outcome.nil?

    outcome_group_json(root_outcome, @current_user, session)
  end
  protected :get_root_outcome

  private

  def can_manage_rubrics_or_association_object?(object)
    return true if (object && (can_update?(object) || (can_read?(object) && can_manage_rubrics_context?))) ||
                   (!object && can_manage_rubrics_context?)

    render_unauthorized_action
    false
  end

  def can_update?(object)
    object.grants_right?(@current_user, session, :update)
  end

  def can_read?(object)
    object.grants_right?(@current_user, session, :read)
  end

  def can_manage_rubrics_context?
    @context.grants_right?(@current_user, session, :manage_rubrics)
  end

  def track_metrics
    if @association_object.is_a?(Assignment)
      InstStatsd::Statsd.distributed_increment("#{@context.class.to_s.downcase}.rubrics.created_from_assignment")
    end
  end
end
