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

class OutcomeGroupsController < ApplicationController
  before_action :require_context

  def create
    if authorized_action(@context, @current_user, :manage_outcomes)
      parent_id = params[:learning_outcome_group].delete(:learning_outcome_group_id)
      parent_outcome_group = parent_id ? @context.learning_outcome_groups.find(parent_id) : @context.root_outcome_group
      @outcome_group = parent_outcome_group.child_outcome_groups.build(params[:learning_outcome_group].merge(context: @context))
      @outcome_group.description = process_incoming_html_content(@outcome_group.description) if @outcome_group.description
      @outcome_group.saving_user = @current_user
      respond_to do |format|
        if @outcome_group.save
          format.json { render json: @outcome_group }
        else
          format.json { render json: @outcome_group.errors, status: :bad_request }
        end
      end
    end
  end

  def import
    if authorized_action(@context, @current_user, :manage_outcomes)
      data = begin
        JSON.parse(params[:file].read).with_indifferent_access
      rescue JSON::ParserError
        nil
      end
      if data && data[:category] && data[:title] && data[:description] && data[:outcomes]
        group = @context.learning_outcome_groups.create
        data[:outcomes].each do
          group.learning_outcomes.create
        end
        render json: group.as_json(include: :learning_outcomes)
      else
        render json: { errors: { base: t(:invalid_file, "Invalid outcome group file") } },
               status: :bad_request
      end
    end
  end

  def update
    if authorized_action(@context, @current_user, :manage_outcomes)
      @outcome_group = @context.learning_outcome_groups.active.find(params[:id])
      respond_to do |format|
        parent_id = params[:learning_outcome_group].delete(:learning_outcome_group_id)
        @outcome_group.attributes = params[:learning_outcome_group]
        @outcome_group.learning_outcome_group = @context.learning_outcome_groups.find(parent_id) if parent_id
        @outcome_group.description = process_incoming_html_content(@outcome_group.description) if @outcome_group.description
        @outcome_group.saving_user = @current_user
        if @outcome_group.save
          format.json { render json: @outcome_group }
        else
          format.json { render json: @outcome_group.errors, status: :bad_request }
        end
      end
    end
  end

  def destroy
    if authorized_action(@context, @current_user, :manage_outcomes)
      @outcome_group = @context.learning_outcome_groups.active.find(params[:id])
      @outcome_group.skip_tag_touch = true
      @outcome_group.destroy
      @context.touch
      render json: @outcome_group
    end
  end
end
