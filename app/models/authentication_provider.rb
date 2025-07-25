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

require "net-ldap"
require "net_ldap_extensions"
NetLdapExtensions.apply

class AuthenticationProvider < ActiveRecord::Base
  include Workflow
  validates :auth_filter, length: { maximum: maximum_text_length, allow_blank: true }

  DEBUG_EXPIRE = 30.minutes

  workflow do
    state :active
    state :deleted
  end

  self.inheritance_column = :auth_type
  # backcompat while authentication_providers might be a view
  self.primary_key = "id"

  def self.subclass_from_attributes?(_)
    false
  end

  # we have a lot of old data that didn't actually use STI,
  # so we shim it
  def self.find_sti_class(type_name)
    return self if type_name.blank? # super no longer does this in Rails 4

    case type_name
    when "cas", "ldap", "saml"
      const_get(type_name.upcase)
    when "apple", "clever", "facebook", "google", "microsoft", "saml_idp_discovery"
      const_get(type_name.classify)
    when "canvas"
      Canvas
    when "github"
      GitHub
    when "linkedin"
      LinkedIn
    when "openid_connect"
      OpenIDConnect
    else
      super
    end
  end

  def self.sti_name
    display_name.try(:underscore)
  end

  def self.singleton?
    false
  end

  def self.restorable?
    false
  end

  def self.enabled?(_account = nil, _user = nil)
    true
  end

  def self.supports_debugging?
    false
  end

  def self.debugging_enabled?
    ::Canvas.redis_enabled?
  end

  def self.display_name
    name.try(:demodulize)
  end

  def self.login_message
    t("Login with %{provider}", provider: display_name)
  end

  def self.supports_autoconfirmed_email?
    true
  end

  scope :active, -> { where.not(workflow_state: "deleted") }
  belongs_to :account
  include ::Canvas::RootAccountCacher
  has_many :pseudonyms, inverse_of: :authentication_provider
  acts_as_list scope: { account: self, workflow_state: [nil, "active"] }

  def self.valid_auth_types
    %w[apple canvas cas clever facebook github google ldap linkedin microsoft openid_connect saml saml_idp_discovery].freeze
  end

  validates :auth_type,
            inclusion: { in: ->(_) { valid_auth_types },
                         message: ->(_object, _data) { "invalid auth_type, must be one of #{valid_auth_types.join(",")}" } }
  validates :account_id, presence: true
  validate :validate_federated_attributes

  # create associate model find to accept auth types, and just return the first one of that
  # type
  module FindWithType
    def find(*args)
      if AuthenticationProvider.valid_auth_types.include?(args.first)
        where(auth_type: args.first).first!
      else
        super
      end
    end
  end

  def self.recognized_params
    %i[mfa_required skip_internal_mfa otp_via_sms].freeze
  end

  def self.site_admin_params
    [].freeze
  end

  def self.deprecated_params
    [].freeze
  end

  def self.sensitive_params
    [].freeze
  end

  def self.login_button?
    Rails.root.join("app/views/shared/svg/_svg_icon_#{sti_name}.svg").exist?
  end

  def self.find_restorable_provider(root_account:, auth_type:)
    provider_class = find_sti_class(auth_type)

    # To be a restore candidate, an authentication provider must be
    # singleton and explicitly marked as restorable
    return unless provider_class.singleton? && provider_class.restorable?

    root_account.authentication_providers.where.not(workflow_state: :active).find_by(auth_type:)
  end

  def visible_to?(_user)
    true
  end

  def login_attribute_for_pseudonyms
    nil
  end

  def destroy
    send(:remove_from_list_for_destroy)
    self.workflow_state = "deleted"
    save!
    enable_canvas_authentication
    delay_if_production.soft_delete_pseudonyms unless self.class.restorable?
    true
  end
  alias_method :destroy_permanently!, :destroy

  def restore
    timestamp = updated_at
    self.workflow_state = "active"
    if save
      move_to_bottom
      fix_position_conflicts
      delay_if_production.restore_soft_deleted_pseudonyms(timestamp)
      true
    end
  end

  def auth_password=(password)
    return if password.blank?

    self.auth_crypted_password, self.auth_password_salt = ::Canvas::Security.encrypt_password(password, "instructure_auth")
  end

  def auth_decrypted_password
    return nil unless auth_password_salt && auth_crypted_password

    ::Canvas::Security.decrypt_password(auth_crypted_password, auth_password_salt, "instructure_auth")
  end

  def auth_provider_filter
    self
  end

  def self.default_login_handle_name
    t(:default_login_handle_name, "Email")
  end

  def self.default_delegated_login_handle_name
    t(:default_delegated_login_handle_name, "Login")
  end

  def self.serialization_excludes
    [:auth_crypted_password, :auth_password_salt]
  end

  # allowable attributes for federated_attributes setting; nil means anything
  # is allowed
  def self.recognized_federated_attributes
    [].freeze
  end

  def settings
    super || {}
  end

  def federated_attributes=(value)
    value = {} unless value.is_a?(Hash)
    settings_will_change! unless value == federated_attributes
    settings["federated_attributes"] = value
  end

  def federated_attributes
    settings["federated_attributes"] ||= {}
  end

  def mfa_required?
    return false if account.mfa_settings == :disabled
    return true if account.mfa_settings == :required

    !!settings["mfa_required"]
  end
  alias_method :mfa_required, :mfa_required?

  def mfa_required=(value)
    value = false if account.mfa_settings == :disabled
    settings["mfa_required"] = ::Canvas::Plugin.value_to_boolean(value)
  end

  def skip_internal_mfa?
    !!settings["skip_internal_mfa"]
  end
  alias_method :skip_internal_mfa, :skip_internal_mfa?

  def skip_internal_mfa=(value)
    settings["skip_internal_mfa"] = ::Canvas::Plugin.value_to_boolean(value)
  end

  # Default to true if not set, for backwards compatibility/opt-out
  def otp_via_sms?
    if settings.key?("otp_via_sms")
      !!settings["otp_via_sms"]
    else
      true
    end
  end
  alias_method :otp_via_sms, :otp_via_sms?

  def otp_via_sms=(value)
    settings["otp_via_sms"] = ::Canvas::Plugin.value_to_boolean(value)
  end

  def federated_attributes_for_api
    if jit_provisioning?
      federated_attributes
    else
      result = {}
      federated_attributes.each do |(canvas_attribute_name, provider_attribute_config)|
        next if provider_attribute_config["provisioning_only"]

        result[canvas_attribute_name] = provider_attribute_config["attribute"]
      end
      result
    end
  end

  CANVAS_ALLOWED_FEDERATED_ATTRIBUTES = %w[
    admin_roles
    display_name
    email
    given_name
    integration_id
    locale
    name
    sis_user_id
    sortable_name
    surname
    time_zone
  ].freeze

  def provision_user(unique_ids, provider_attributes = {})
    unique_id = nil
    User.transaction(requires_new: true) do
      if unique_ids.is_a?(Hash)
        unique_id = unique_ids[login_attribute]
      else
        unique_id = unique_ids
        unique_ids = {}
      end
      pseudonym = account.pseudonyms.build
      pseudonym.user = User.create!(name: unique_id) { |u| u.workflow_state = "registered" }
      pseudonym.authentication_provider = self
      pseudonym.unique_id = unique_id
      pseudonym.unique_ids = unique_ids
      pseudonym.save!
      apply_federated_attributes(pseudonym, provider_attributes, purpose: :provisioning)
      try(:post_provision_user, pseudonym:, provider_attributes:)
      pseudonym
    end
  rescue ActiveRecord::RecordNotUnique
    self.class.uncached do
      pseudonyms.active_only.by_unique_id(unique_id).take
    end
  end

  def apply_federated_attributes(pseudonym, provider_attributes, purpose: :login)
    user = pseudonym.user

    canvas_attributes = translate_provider_attributes(provider_attributes,
                                                      purpose:)
    given_name = canvas_attributes.delete("given_name")
    surname = canvas_attributes.delete("surname")
    if given_name || surname
      user.name = "#{given_name} #{surname}"
      user.sortable_name = if given_name.present? && surname.present?
                             "#{surname}, #{given_name}"
                           else
                             "#{given_name}#{surname}"
                           end
    end

    User.transaction do
      canvas_attributes.each do |(attribute, value)|
        # ignore attributes with no value sent; we don't process "deletions" yet
        next unless value

        case attribute
        when "admin_roles"
          role_names = value.is_a?(String) ? value.split(",").map(&:strip) : value
          account = pseudonym.account
          existing_account_users = account.account_users.merge(user.account_users).preload(:role).to_a
          roles = role_names.filter_map do |role_name|
            account.get_account_role_by_name(role_name)
          end
          roles_to_add = roles - existing_account_users.map(&:role)
          account_users_to_delete = existing_account_users.select { |au| au.active? && !roles.include?(au.role) }
          account_users_to_activate = existing_account_users.select { |au| au.deleted? && roles.include?(au.role) }
          roles_to_add.each do |role|
            account.account_users.create!(user:, role:)
          end
          account_users_to_delete.each(&:destroy)
          account_users_to_activate.each(&:reactivate)
        when "sis_user_id", "integration_id"
          next if value.empty?
          next if pseudonym.account.pseudonyms.where(attribute => value).exists?

          pseudonym[attribute] = value
        when "display_name"
          user.short_name = value
        when "email"
          next if value.empty?

          autoconfirm = self.class.supports_autoconfirmed_email? && federated_attributes.dig("email", "autoconfirm")
          Array.wrap(value).uniq.each do |email|
            cc = user.communication_channels.email.by_path(email).first
            cc ||= user.communication_channels.email.new(path: email)
            if autoconfirm
              cc.workflow_state = "active"
            elsif cc.new_record?
              cc.workflow_state = "unconfirmed"
            end
            if cc.changed?
              cc.save!
              cc.send_confirmation!(pseudonym.account) unless autoconfirm
            end
          end
        when "locale"
          lowercase_locales = I18n.available_locales.map { |locale| locale.to_s.downcase }

          Array.wrap(value).uniq.map do |locale|
            # convert _ to -, be lenient about case
            locale = locale.tr("_", "-")
            while locale.include?("-")
              break if lowercase_locales.include?(locale.downcase)

              locale = locale.sub(/(?:x-)?-[^-]*$/, "")
            end
            if (i = lowercase_locales.index(locale.downcase))
              user.locale = I18n.available_locales[i].to_s
              break
            end
          end
        else
          user.send(:"#{attribute}=", value)
        end
      end
      if pseudonym.changed? && !pseudonym.save
        Rails.logger.warn("Unable to save federated pseudonym: #{pseudonym.errors.to_hash}")
      end
      if user.changed? && !user.save
        Rails.logger.warn("Unable to save federated user: #{user.errors.to_hash}")
      end
      try(:post_federated_attribute_application, pseudonym:, provider_attributes:)
    end
  end

  def debugging?
    return false unless self.class.debugging_enabled?

    unless instance_variable_defined?(:@debugging)
      @debugging = !!debug_get(:debugging)
    end
    @debugging
  end

  def stop_debugging
    self.class.debugging_keys.map(&:keys).flatten.each { |key| ::Canvas.redis.del(debug_key(key)) }
  end

  def start_debugging
    stop_debugging # clear old data
    debug_set(:debugging, t("Waiting for attempted login"))
    @debugging = true
  end

  def debug_get(key)
    ::Canvas.redis.get(debug_key(key), failsafe: nil)
  end

  def debug_set(key, value, overwrite: true)
    ::Canvas.redis.set(debug_key(key), value, ex: DEBUG_EXPIRE.to_i, nx: overwrite ? nil : true)
  end

  def duplicated_in_account?
    return false unless self.class.singleton?

    account.authentication_providers.active.where(auth_type:).where.not(id:).exists?
  end

  protected

  def statsd_prefix
    "auth.account_#{Shard.global_id_for(account_id)}.config_#{global_id}"
  end

  private

  BOOLEAN_ATTRIBUTE_PROPERTIES = %w[provisioning_only autoconfirm].freeze
  private_constant :BOOLEAN_ATTRIBUTE_PROPERTIES

  def validate_federated_attributes
    bad_keys = federated_attributes.keys - CANVAS_ALLOWED_FEDERATED_ATTRIBUTES
    unless bad_keys.empty?
      errors.add(:federated_attributes, "#{bad_keys.join(", ")} is not an attribute that can be federated")
      return
    end

    # normalize values to { attribute: <attribute>, provisioning_only: true|false }
    federated_attributes.each_key do |key|
      case (attr = federated_attributes[key])
      when String
        attr = federated_attributes[key] = { "attribute" => federated_attributes[key], "provisioning_only" => false }
        attr["autoconfirm"] = false if key == "email"
      when Hash
        bad_keys = attr.keys - ["attribute", "provisioning_only"]
        bad_keys.delete("autoconfirm") if key == "email"
        unless bad_keys.empty?
          errors.add(:federated_attributes, "unrecognized key #{bad_keys.join(", ")} in #{key} attribute definition")
          return
        end
        unless attr.key?("attribute")
          errors.add(:federated_attributes, "missing key attribute in #{key} attribute definition")
          return
        end

        BOOLEAN_ATTRIBUTE_PROPERTIES.each do |prop|
          next if prop == "autoconfirm" && key != "email"

          attr[prop] = ::Canvas::Plugin.value_to_boolean(attr[prop])
        end
      else
        errors.add(:federated_attributes, "invalid attribute definition for #{key}")
        return
      end
    end

    return if self.class.recognized_federated_attributes.nil?

    bad_values = federated_attributes.values.pluck("attribute") - self.class.recognized_federated_attributes
    unless bad_values.empty?
      errors.add(:federated_attributes, "#{bad_values.join(", ")} is not a valid attribute")
    end
  end

  def translate_provider_attributes(provider_attributes, purpose:)
    result = {}
    federated_attributes.each do |(canvas_attribute_name, provider_attribute_config)|
      next if purpose != :provisioning && provider_attribute_config["provisioning_only"]

      provider_attribute_name = provider_attribute_config["attribute"]

      if provider_attributes.key?(provider_attribute_name)
        result[canvas_attribute_name] = provider_attributes[provider_attribute_name]
      end
    end
    result
  end

  def soft_delete_pseudonyms
    pseudonyms.find_each do |pseudonym|
      unless pseudonym.deleted?
        pseudonym.destroy(custom_deleted_at: updated_at)
      end
    end
  end

  def restore_soft_deleted_pseudonyms(timestamp)
    provider_updated_at_before_restore_timestamp = timestamp
    pseudonyms.find_each do |pseudonym|
      if pseudonym.deleted? && pseudonym.deleted_at == provider_updated_at_before_restore_timestamp
        pseudonym.restore
      end
    end
  end

  def enable_canvas_authentication
    return if account.non_canvas_auth_configured?

    account.enable_canvas_authentication
  end

  def debug_key(key)
    ["auth_provider_debugging", global_id, key.to_s].cache_key
  end
end
