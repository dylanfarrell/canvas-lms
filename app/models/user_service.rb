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

class UserService < ActiveRecord::Base
  include Workflow

  belongs_to :user
  attr_reader :password

  validates :user_id, :service, :service_user_id, :workflow_state, presence: true
  validates :service_user_id, :service_user_name, length: { maximum: maximum_string_length }

  before_save :infer_defaults
  after_save :assert_relations
  after_save :touch_user
  after_save :clear_cache_key

  def assert_relations
    if user_id && service
      UserService.where(user_id:, service:).where("id<>?", self).delete_all
    end
    true
  end

  def clear_cache_key
    user.clear_cache_key(:user_services)
  end

  def infer_defaults
    self.refresh_at ||= Time.now.utc
  end
  protected :infer_defaults

  workflow do
    state :active do
      event :failed_request, transitions_to: :failed
    end

    state :failed
  end

  scope :of_type, ->(type) { where(type: type.to_s) }

  scope :to_be_polled, -> { where("refresh_at<", Time.now.utc).order(:refresh_at).limit(1) }
  scope :for_user, ->(user) { where(user_id: user) }
  scope :for_service, lambda { |service|
    service = service.service if service.is_a?(UserService)
    where(service: service.to_s)
  }
  scope :visible, -> { where("visible") }

  def service_name
    service.titleize
  end

  def password=(password)
    self.crypted_password, self.password_salt = Canvas::Security.encrypt_password(password, "instructure_user_service")
  end

  def decrypted_password
    return nil unless password_salt && crypted_password

    Canvas::Security.decrypt_password(crypted_password, password_salt, "instructure_user_service")
  end

  def self.register(opts = {})
    raise "User required" unless opts[:user]

    token = opts[:access_token] ? opts[:access_token].token : opts[:token]
    secret = opts[:access_token] ? opts[:access_token].secret : opts[:secret]
    domain = opts[:service_domain] || "google.com"
    service = opts[:service] || "google_docs"
    protocol = opts[:protocol] || "oauth"
    user_service = opts[:user].user_services.where(service:, protocol:).first_or_initialize
    user_service.service_domain = domain
    user_service.token = token
    user_service.secret = secret
    user_service.service_user_id = opts[:service_user_id] if opts[:service_user_id]
    user_service.service_user_name = opts[:service_user_name] if opts[:service_user_name]
    user_service.service_user_url = opts[:service_user_url] if opts[:service_user_url]
    user_service.password = opts[:password] if opts[:password]
    user_service.type = service_type(service)
    user_service.save!
    user_service
  end

  def self.register_from_params(user, params = {})
    opts = {}
    opts[:user] = user
    opts[:access_token] = nil
    opts[:token] = nil
    opts[:secret] = nil
    opts[:service] = params[:service]
    case opts[:service]
    when "diigo"
      opts[:service_domain] = "diigo.com"
      opts[:protocol] = "http-auth"
      opts[:service_user_id] = params[:user_name]
      opts[:service_user_name] = params[:user_name]
      opts[:password] = params[:password]
    when "skype"
      opts[:service_domain] = "skype.com"
      opts[:service_user_id] = params[:user_name]
      opts[:service_user_name] = params[:user_name]
      opts[:protocol] = "skype"
    else
      raise "Unknown Service Type"
    end
    register(opts)
  end

  def has_profile_link?
    true
  end

  def has_readable_user_name?
    service == "google_drive"
  end

  def self.sort_position(type)
    case type
    when "google_drive"
      2
    when "skype"
      3
    when "diigo"
      8
    else
      999
    end
  end

  def self.short_description(type)
    case type
    when "google_drive"
      t "#user_service.descriptions.google_drive", "Students can use Google Drive to collaborate on group projects.  Google Drive allows for real-time collaborative editing of documents, spreadsheets and presentations."
    when "diigo"
      t "#user_service.descriptions.diigo", "Diigo is a collaborative link-sharing tool.  You can tag any page on the Internet for later reference.  You can also link to other users' Diigo accounts to share links of similar interest."
    when "skype"
      t "#user_service.descriptions.skype", "Skype is a free tool for online voice and video calls."
    else # 'google_calendar'
      ""
    end
  end

  def self.registration_url(type)
    case type
    when "google_drive"
      "https://www.google.com/drive/"
    when "google_calendar"
      "http://calendar.google.com"
    when "diigo"
      "https://www.diigo.com/sign-up"
    when "skype"
      "http://www.skype.com/go/register"
    else
      nil
    end
  end

  def service_user_link
    case service
    when "google_drive"
      "https://myaccount.google.com/?pli=1"
    when "google_calendar"
      "http://calendar.google.com"
    when "diigo"
      "http://www.diigo.com/user/#{service_user_name}"
    when "skype"
      "skype:#{service_user_name}?add"
    else
      "http://www.instructure.com"
    end
  end

  def self.service_type(type)
    case type
    when "google_docs", "google_drive"
      "DocumentService"
    when "diigo"
      "BookmarkService"
    else
      "UserService"
    end
  end

  def self.serialization_excludes
    %i[crypted_password password_salt token secret]
  end

  def self.associated_shards(_service, _service_user_id)
    [Shard.default]
  end
end
