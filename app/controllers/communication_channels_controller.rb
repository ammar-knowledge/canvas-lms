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

# @API Communication Channels
#
# API for accessing users' email and SMS communication channels.
#
# In this API, the `:user_id` parameter can always be replaced with `self` if
# the requesting user is asking for his/her own information.
#
# @model CommunicationChannel
#     {
#       "id": "CommunicationChannel",
#       "description": "",
#       "properties": {
#         "id": {
#           "description": "The ID of the communication channel.",
#           "example": 16,
#           "type": "integer"
#         },
#         "address": {
#           "description": "The address, or path, of the communication channel.",
#           "example": "sheldon@caltech.example.com",
#           "type": "string"
#         },
#         "type": {
#           "description": "The type of communcation channel being described. Possible values are: 'email', 'push', 'sms'. This field determines the type of value seen in 'address'.",
#           "example": "email",
#           "type": "string",
#           "allowableValues": {
#             "values": [
#               "email",
#               "push",
#               "sms"
#             ]
#           }
#         },
#         "position": {
#           "description": "The position of this communication channel relative to the user's other channels when they are ordered.",
#           "example": 1,
#           "type": "integer"
#         },
#         "user_id": {
#           "description": "The ID of the user that owns this communication channel.",
#           "example": 1,
#           "type": "integer"
#         },
#         "bounce_count": {
#           "description": "The number of bounces the channel has experienced. This is reset if the channel sends successfully.",
#           "example": 0,
#           "type": "integer"
#         },
#         "last_bounce_at": {
#           "description": "The time the last bounce occurred.",
#           "example": "2012-05-30T17:00:00Z",
#           "type": "datetime"
#         },
#         "workflow_state": {
#           "description": "The current state of the communication channel. Possible values are: 'unconfirmed' or 'active'.",
#           "example": "active",
#           "type": "string",
#           "allowableValues": {
#             "values": [
#               "unconfirmed",
#               "active"
#             ]
#           }
#         }
#       }
#     }
#
class CommunicationChannelsController < ApplicationController
  before_action :require_user, only: %i[create destroy re_send_confirmation delete_push_token]
  before_action :reject_student_view_student

  include Api::V1::CommunicationChannel

  # @API List user communication channels
  #
  # Returns a paginated list of communication channels for the specified user,
  # sorted by position.
  #
  # @example_request
  #     curl https://<canvas>/api/v1/users/12345/communication_channels \
  #          -H 'Authorization: Bearer <token>'
  #
  # @returns [CommunicationChannel]
  def index
    @user = api_find(User, params[:user_id])
    return unless authorized_action(@user, @current_user, :read)

    channels = Api.paginate(@user.communication_channels.unretired,
                            self,
                            api_v1_communication_channels_url).map do |cc|
      communication_channel_json(cc, @current_user, session)
    end

    render json: channels
  end

  # @API Create a communication channel
  #
  # Creates a new communication channel for the specified user.
  #
  # @argument communication_channel[address] [Required, String]
  #   An email address or SMS number. Not required for "push" type channels.
  #
  # @argument communication_channel[type] [Required, String, "email"|"sms"|"push"]
  #   The type of communication channel.
  #
  #   In order to enable push notification support, the server must be
  #   properly configured (via `sns_creds` in Vault) to communicate with Amazon
  #   Simple Notification Services, and the developer key used to create
  #   the access token from this request must have an SNS ARN configured on
  #   it.
  #
  # @argument communication_channel[token] [String]
  #   A registration id, device token, or equivalent token given to an app when
  #   registering with a push notification provider. Only valid for "push" type channels.
  #
  #
  # @argument skip_confirmation [Boolean]
  #   Only valid for site admins and account admins making requests; If true, the channel is
  #   automatically validated and no confirmation email or SMS is sent.
  #   Otherwise, the user must respond to a confirmation message to confirm the
  #   channel.
  #
  # @example_request
  #     curl https://<canvas>/api/v1/users/1/communication_channels \
  #          -H 'Authorization: Bearer <token>' \
  #          -d 'communication_channel[address]=new@example.com' \
  #          -d 'communication_channel[type]=email' \
  #
  # @returns CommunicationChannel
  def create
    @user = api_request? ? api_find(User, params[:user_id]) : @current_user

    if !has_api_permissions? && params[:communication_channel][:type] != CommunicationChannel::TYPE_PUSH
      return render_unauthorized_action
    end

    # We are doing the check here because it takes a lot of queries to get from
    # the CC model to the domain_root_account, and 99% of the time that will end
    # up being wasted work.
    unless CommunicationChannel.user_can_have_more_channels?(@current_user, @domain_root_account)
      error = t "Maximum number of communication channels reached"
      return render json: { errors: { type: error } }, status: :bad_request
    end

    params[:build_pseudonym] = false if api_request?

    skip_confirmation = value_to_boolean(params[:skip_confirmation]) &&
                        (Account.site_admin.grants_right?(@current_user, :manage_students) || @domain_root_account.grants_right?(@current_user, :manage_students))

    InstStatsd::Statsd.distributed_increment("communication_channels.create.skip_confirmation") if skip_confirmation

    if params[:communication_channel][:type] == CommunicationChannel::TYPE_PUSH
      unless @access_token
        return render json: { errors: { type: "Push is only supported when using an access token" } }, status: :bad_request
      end
      unless @access_token.developer_key.try(:sns_arn)
        return render json: { errors: { type: "SNS is not configured for this developer key" } }, status: :bad_request
      end

      NotificationEndpoint.unique_constraint_retry do
        unless @access_token.notification_endpoints.where("lower(token) = lower(?)", params[:communication_channel][:token]).exists?
          @access_token.notification_endpoints.create!(token: params[:communication_channel][:token])
        end
      end

      skip_confirmation = true
      params[:build_pseudonym] = nil
      params[:communication_channel][:address] = "push"
    end

    # If a new pseudonym is requested, build (but don't save) a pseudonym to ensure
    # that the unique_id is valid. The pseudonym will be created on approval of the
    # communication channel.
    if params[:build_pseudonym]
      @pseudonym = @domain_root_account.pseudonyms.build(user: @user,
                                                         unique_id: params[:communication_channel][:address])
      @pseudonym.generate_temporary_password

      unless @pseudonym.valid?
        return render json: @pseudonym.errors.as_json, status: :bad_request
      end
    end

    # Find or create the communication channel.
    @cc ||= @user.communication_channels.by_path(params[:communication_channel][:address])
                 .where(path_type: params[:communication_channel][:type]).first
    @cc.path = params[:communication_channel][:address] if @cc
    @cc ||= @user.communication_channels.build(path: params[:communication_channel][:address],
                                               path_type: params[:communication_channel][:type])

    if !@cc.new_record? && !@cc.retired? && @cc.path_type != CommunicationChannel::TYPE_PUSH
      @cc.errors.add(:path, "unique!")
      return render json: @cc.errors.as_json, status: :bad_request
    end

    @cc.user = @user
    @cc.build_pseudonym_on_confirm = value_to_boolean(params[:build_pseudonym])
    @cc.re_activate! if @cc.retired?
    @cc.workflow_state = skip_confirmation ? "active" : "unconfirmed"

    cc_saved = User.transaction do
      saved =  @cc.save
      if saved
        # need to change them from pre-registered to registered them as well
        # so that they can get notifications
        @user.register if skip_confirmation
      end
      saved
    end

    if cc_saved
      @cc.send_confirmation!(@domain_root_account) unless skip_confirmation
      flash[:notice] = t("profile.notices.contact_registered", "Contact method registered!")
      render json: communication_channel_json(@cc, @current_user, session)
    else
      render json: @cc.errors.as_json, status: :bad_request
    end
  end

  def confirm
    @nonce = params[:nonce]
    cc = CommunicationChannel.unretired.where.not(path_type: CommunicationChannel::TYPE_PUSH).find_by_confirmation_code(@nonce)

    # See if we can find it cross shard if it wasn't found on this shard
    cc ||= @current_user && @current_user.communication_channels.unretired.where.not(path_type: CommunicationChannel::TYPE_PUSH).find_by_confirmation_code(@nonce)

    @headers = false
    if (!cc || (cc.path_type == "email" && !EmailAddressValidator.valid?(cc.path))) ||
       (@domain_root_account.allow_additional_email_at_registration? &&
        params.dig(:pseudonym, :personal_email).present? &&
        !EmailAddressValidator.valid?(params[:pseudonym][:personal_email]))
      failed = true
    else
      @communication_channel = cc
      @user = cc.user
      @enrollment = @user.enrollments.where(uuid: params[:enrollment], workflow_state: "invited").first if params[:enrollment].present?
      @course = @enrollment&.course
      @root_account = @course.root_account if @course
      @root_account ||= @user.pseudonyms.first.try(:account) if @user.pre_registered?
      @root_account ||= @user.enrollments.first.try(:root_account) if @user.creation_pending?
      unless @root_account
        account = @user.adminable_accounts.first
        @root_account = account.try(:root_account)
      end
      @root_account ||= @domain_root_account

      # now that we've retrieved a communication channel record with our
      # nonce we can set the locale based on the associated models
      I18n.localizer = lambda do
        infer_locale user: @user,
                     root_account: @root_account
      end

      # logged in as an unconfirmed user?! someone's masquerading; just pretend we're not logged in at all
      if @current_user == @user && !@user.registered?
        @current_user = nil
      end

      if @user.registered? && cc.unconfirmed?
        unless @current_user == @user
          add_additional_email_if_allowed
          session[:return_to] = request.url
          flash[:notice] = t "notices.login_to_confirm", "Please log in to confirm your e-mail address"
          redirect_to login_url(pseudonym_session: { unique_id: @user.pseudonym.try(:unique_id) }, expected_user_id: @user.id)
          return
        end

        User.transaction do
          add_additional_email_if_allowed
          cc.confirm
          @user.touch
        end
        return respond_to do |format|
          format.html do
            flash[:notice] = t "notices.registration_confirmed", "Registration confirmed!"
            redirect_to redirect_back_or_default(user_profile_url(@current_user))
          end
          format.json { render json: cc.as_json(except: [:confirmation_code]) }
        end
      end

      # load merge opportunities
      if @domain_root_account.feature_enabled?(:self_service_user_merge)
        merge_users = cc.merge_candidates
        merge_users << @current_user if @current_user && !@user.registered? && !merge_users.include?(@current_user)
        observer_links = UserObservationLink.active.where("user_id = ? OR observer_id = ?", @user.id, @user.id)
        merge_users = merge_users.reject { |u| observer_links.any? { |uo| uo.user == u || uo.observer == u } }
        # remove users that don't have a pseudonym for this account, or one can't be created
        merge_users = merge_users.select { |u| u.find_or_initialize_pseudonym_for_account(@root_account, @domain_root_account) }
        @merge_opportunities = []
        merge_users.each do |user|
          account_to_pseudonyms_hash = {}
          root_account_pseudonym = SisPseudonym.for(user, @root_account, type: :exact, require_sis: false)
          if root_account_pseudonym
            @merge_opportunities << [user, [root_account_pseudonym]]
          else
            user.all_active_pseudonyms.each do |p|
              # populate reverse association
              p.user = user
              (account_to_pseudonyms_hash[p.account] ||= []) << p
            end
            @merge_opportunities << [user,
                                     account_to_pseudonyms_hash.each_value.map do |pseudonyms|
                                       pseudonyms.detect(&:sis_user_id) || pseudonyms.min_by(&:position)
                                     end]
            @merge_opportunities.last.last.sort! { |a, b| Canvas::ICU.compare(a.account.name, b.account.name) }
          end
        end
        @merge_opportunities.sort_by! { |a| [(a.first == @current_user) ? CanvasSort::First : CanvasSort::Last, Canvas::ICU.collation_key(a.first.name)] }
      else
        @merge_opportunities = []
      end

      js_env PASSWORD_POLICY: @domain_root_account.password_policy

      if @current_user && params[:confirm].present? && @merge_opportunities.find { |opp| opp.first == @current_user }
        @user.transaction do
          @current_user.transaction do
            cc.confirm
            @enrollment&.accept
            UserMerge.from(@user).into(@current_user, merger: @current_user, source: "cc_confirmation") if @user != @current_user
            # create a new pseudonym if necessary and possible
            pseudonym = @current_user.find_or_initialize_pseudonym_for_account(@root_account, @domain_root_account)
            pseudonym.save! if pseudonym&.changed?
          end
        end
      elsif @current_user && @current_user != @user && @enrollment && @user.registered?
        if params[:transfer_enrollment].present?
          @current_user.associate_with_shard(@enrollment.shard)
          @user.transaction do
            @current_user.transaction do
              # cc will be active, so we will never call confirm here. If the user is already registered and the
              # cc is not active, we would have entered the if block above, which returns from this method.
              cc.active? || cc.confirm
              @enrollment.user = @current_user
              # accept will save it
              @enrollment.accept
              @user.touch
              @current_user.touch
            end
          end
        else
          # render
          return
        end
      elsif @user.registered?
        # render
        return unless @merge_opportunities.empty?

        failed = true
      elsif cc.active?
        pseudonym = @root_account.pseudonyms.active_only.where(user_id: @user).exists?
        if @user.pre_registered? && pseudonym
          User.transaction do
            @user.register
            add_additional_email_if_allowed
          end
          return redirect_with_success_flash
        else
          failed = true
        end
      else
        # Open registration and admin-created users are pre-registered, and have already claimed a CC, but haven't
        # set up a password yet
        @pseudonym = @root_account.pseudonyms.active_only.where(password_auto_generated: true, user_id: @user).first if @user.pre_registered? || @user.creation_pending?
        # Users implicitly created via course enrollment or account admin creation are creation pending, and don't have a pseudonym yet
        @pseudonym ||= @root_account.pseudonyms.build(user: @user, unique_id: cc.path) if @user.creation_pending?
        # We create the pseudonym with unique_id = cc.path, but if that unique_id is taken, just nil it out and make the user come
        # up with something new
        @pseudonym.unique_id = "" if @pseudonym&.new_record? && @root_account.pseudonyms.active_only.by_unique_id(@pseudonym.unique_id).exists?

        # Have to either have a pseudonym to register with, or be looking at merge opportunities
        return render :confirm_failed, status: :bad_request if !@pseudonym && @merge_opportunities.empty?

        # User chose to continue with this cc/pseudonym/user combination on confirmation page
        if @pseudonym && params[:register]
          @user.require_acceptance_of_terms = require_terms?
          @user.attributes = params[:user].permit(:time_zone, :subscribe_to_emails, :terms_of_use) if params[:user]

          if params[:pseudonym]
            pseudonym_params = params[:pseudonym].permit(:password, :password_confirmation, :unique_id)
            if @pseudonym.unique_id.present?
              pseudonym_params.delete(:unique_id)
            end
            @pseudonym.attributes = pseudonym_params
          end

          @pseudonym.communication_channel = cc

          # ensure the password gets validated, but don't require confirmation
          @pseudonym.require_password = true
          @pseudonym.password_confirmation = @pseudonym.password = params[:pseudonym][:password] if params[:pseudonym]

          valid = @pseudonym.valid?
          valid = @user.valid? && valid # don't want to short-circuit, since we are interested in the errors
          unless valid
            ps_errors = @pseudonym.errors.as_json[:errors]
            ps_errors.delete(:password_confirmation) unless params[:pseudonym][:password_confirmation]
            return render json: {
                            errors: {
                              user: @user.errors.as_json[:errors],
                              pseudonym: ps_errors
                            }
                          },
                          status: :bad_request
          end

          User.transaction do
            # They may have switched e-mail address when they logged in; create a CC if so
            if @pseudonym.unique_id != cc.path && EmailAddressValidator.valid?(@pseudonym.unique_id)
              new_cc = @user.communication_channels.email.by_path(@pseudonym.unique_id).first
              new_cc ||= @user.communication_channels.build(path: @pseudonym.unique_id)
              new_cc.user = @user
              new_cc.workflow_state = "unconfirmed" if new_cc.retired?
              new_cc.send_confirmation!(@root_account) if new_cc.unconfirmed?
              new_cc.save! if new_cc.changed?
              @pseudonym.communication_channel = new_cc
            end
            @pseudonym.communication_channel.pseudonym = @pseudonym if @pseudonym.communication_channel

            @user.save!
            @pseudonym.save!

            if cc.confirm
              @enrollment&.accept
              reset_session_saving_keys(:return_to)
              @user.register

              # Login, since we're satisfied that this person is the right person.
              @pseudonym_session = PseudonymSession.new(@pseudonym, true)
              @pseudonym_session.save
              add_additional_email_if_allowed
            else
              failed = true
            end
          end
        else
          return # render
        end
      end
    end

    if failed
      respond_to do |format|
        format.html { render :confirm_failed, status: :bad_request }
        format.json { render json: {}, status: :bad_request }
      end
    else
      redirect_with_success_flash
    end
  end

  # params[:enrollment_id] is optional
  def re_send_confirmation
    @user = User.find(params[:user_id])
    # the active shard needs to be searched for the enrollment (not the user's shard)
    @enrollment = params[:enrollment_id] && Enrollment.where(id: params[:enrollment_id], user_id: @user).first!

    if @enrollment
      return render_unauthorized_action unless @current_user.can_create_enrollment_for?(@enrollment.course, session, @enrollment.type)
    else
      return unless authorized_action(@user, @current_user, [:manage, :manage_user_details])
    end

    if @enrollment && (@enrollment.invited? || @enrollment.active?)
      @enrollment.re_send_confirmation!
    elsif @enrollment && @user.registered?
      # do nothing - the enrollment isn't available and they're already registered anyway
    else
      @cc = params[:id].present? ? @user.communication_channels.find(params[:id]) : @user.communication_channel
      @cc.send_confirmation!(@domain_root_account)
    end
    render json: { re_sent: true }
  end

  def confirmation_limit_reached
    @user = User.find(params[:user_id])
    return unless authorized_action(@user, @current_user, [:manage, :manage_user_details])
    return render json: {}, status: :bad_request unless params[:id].present?

    @cc = @user.communication_channels.find(params[:id])
    render json: { confirmation_limit_reached: @cc.confirmation_limit_reached }
  end

  def reset_bounce_count
    @user = api_request? ? api_find(User, params[:user_id]) : @current_user
    @cc = @user.communication_channels.unretired.find(params[:id])
    return render_unauthorized_action unless @cc.grants_right?(@current_user, :reset_bounce_count) || (@real_current_user && @cc.grants_right?(@real_current_user, :reset_bounce_count))

    @cc.reset_bounce_count!

    render json: communication_channel_json(@cc, @current_user, session)
  end

  def redirect_with_success_flash
    @current_user ||= @user # since dashboard_url may need it
    default_url = confirmation_redirect_url(@communication_channel) || dashboard_url
    respond_to do |format|
      format.html do
        flash[:notice] = t "notices.registration_confirmed", "Registration confirmed!"
        redirect_to(@enrollment ? course_url(@course) : redirect_back_or_default(default_url))
      end
      format.json { render json: { url: @enrollment ? course_url(@course) : default_url } }
    end
  end

  def confirmation_redirect_url(communication_channel)
    uri = begin
      URI.parse(communication_channel.confirmation_redirect)
    rescue URI::InvalidURIError
      nil
    end
    return nil unless uri

    if @current_user
      query_params = URI.decode_www_form(uri.query || "") << ["current_user_id", @current_user.id.to_s]
      uri.query = URI.encode_www_form(query_params)
    end
    uri.to_s
  end

  # @API Delete a communication channel
  #
  # Delete an existing communication channel.
  #
  # @example_request
  #     curl https://<canvas>/api/v1/users/5/communication_channels/3
  #          -H 'Authorization: Bearer <token>
  #          -X DELETE
  #
  # @returns CommunicationChannel
  def destroy
    @user = api_request? ? api_find(User, params[:user_id]) : @current_user
    if params[:type] && params[:address]
      @cc = @user.communication_channels.unretired.of_type(params[:type]).by_path(params[:address]).first
      raise ActiveRecord::RecordNotFound unless @cc
    else
      @cc = @user.communication_channels.unretired.find(params[:id])
    end

    return render_unauthorized_action unless has_api_permissions?
    if @cc.imported? && !@domain_root_account.edit_institution_email?
      return render_unauthorized_action
    end

    if @cc.destroy
      @user.touch
      if api_request?
        render json: communication_channel_json(@cc, @current_user, session)
      else
        render json: @cc.as_json
      end
    else
      render json: @cc.errors, status: :bad_request
    end
  end

  # @API Delete a push notification endpoint
  #
  # @example_request
  #     curl https://<canvas>/api/v1/users/self/communication_channels/push
  #          -H 'Authorization: Bearer <token>
  #          -X DELETE
  #          -d 'push_token=<push_token>'
  #
  # @returns {success: true}
  def delete_push_token
    @cc = @current_user.communication_channels.unretired.of_type(CommunicationChannel::TYPE_PUSH).take
    raise ActiveRecord::RecordNotFound unless @cc

    endpoints = @current_user.notification_endpoints.shard(@current_user).where("lower(token) = ?", params[:push_token].downcase)
    if endpoints&.destroy_all
      @current_user.touch
      render json: { success: true }
    else
      render json: endpoints.errors, status: :bad_request
    end
  end

  def bouncing_channel_report
    generate_bulk_report do
      CommunicationChannel::BulkActions::ResetBounceCounts.new(**bulk_action_args)
    end
  end

  def bulk_reset_bounce_counts
    perform_bulk_action do
      CommunicationChannel::BulkActions::ResetBounceCounts.new(**bulk_action_args)
    end
  end

  def unconfirmed_channel_report
    generate_bulk_report do
      CommunicationChannel::BulkActions::Confirm.new(**bulk_action_args)
    end
  end

  def bulk_confirm
    perform_bulk_action do
      CommunicationChannel::BulkActions::Confirm.new(**bulk_action_args)
    end
  end

  protected

  def account
    @account ||= (params[:account_id] == "self") ? @domain_root_account : Account.find(params[:account_id])
  end

  def bulk_action_args
    args = params.permit(:after, :before, :pattern, :with_invalid_paths, :path_type, :order).to_unsafe_h.symbolize_keys
    args.merge!({ account: })
  end

  def generate_bulk_report
    if account.grants_right?(@current_user, session, :view_bounced_emails)
      action = yield
      respond_to do |format|
        format.csv { send_data(action.csv_report, type: "text/csv") }
        format.json { send_data(action.json_report, type: "application/json") }
      end
    else
      render_unauthorized_action
    end
  end

  def perform_bulk_action
    if authorized_action(Account.site_admin, @current_user, :read_messages)
      action = yield
      render json: action.perform!
    end
  end

  def has_api_permissions?
    (@user == @current_user && @current_user&.user_can_edit_comm_channels?) ||
      @user.grants_right?(@current_user, session, :manage_user_details)
  end

  def add_additional_email_if_allowed
    if @domain_root_account.allow_additional_email_at_registration? && params.dig(:pseudonym, :personal_email).present?
      personal_email = params[:pseudonym][:personal_email]
      new_cc = @user.communication_channels.email.by_path(personal_email).first
      # Don't do anything if for whatever reason the user has already registered the email as a cc.
      unless new_cc
        new_cc = @user.communication_channels.build(path: personal_email, path_type: "personal_email")
        new_cc.user = @user
        new_cc.workflow_state = "unconfirmed"
        new_cc.send_confirmation!(@root_account)
        new_cc.save!
      end
    end
  end

  def require_terms?
    @domain_root_account.require_acceptance_of_terms?(@user)
  end
  helper_method :require_terms?
end
