# frozen_string_literal: true

#
# Copyright (C) 2016 - present Instructure, Inc.
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

describe RuboCop::Cop::Lint::NoSleep do
  subject(:cop) { described_class.new }

  context "controller" do
    before do
      allow(cop).to receive(:file_name).and_return("knights_controller.rb")
    end

    it "disallows sleep" do
      offenses = inspect_source(<<~RUBY)
        class KnightsController < ApplicationController
          def find_sword
            sleep 999
          end
        end
      RUBY
      expect(offenses.size).to eq(1)
      expect(offenses.first.message).to match(/tie up this process/)
      expect(offenses.first.severity.name).to eq(:error)
    end
  end

  context "spec" do
    before do
      allow(cop).to receive(:file_name).and_return("alerts_spec.rb")
    end

    it "disallows sleep" do
      offenses = inspect_source(<<~RUBY)
        describe "Alerts" do
          it "should validate the form" do
            sleep 2
          end
        end
      RUBY
      expect(offenses.size).to eq(1)
      expect(offenses.first.message).to match(/consider: Timecop/)
      expect(offenses.first.severity.name).to eq(:warning)
    end
  end

  context "other" do
    before do
      allow(cop).to receive(:file_name).and_return("bookmark_service.rb")
    end

    it "disallows sleep" do
      offenses = inspect_source(<<~RUBY)
        class BookmarkService < UserService
          def find_bookmarks(query)
            sleep Time.now - last_get
          end
        end
      RUBY
      expect(offenses.size).to eq(1)
      expect(offenses.first.message).to eq("Lint/NoSleep: Avoid using sleep.")
      expect(offenses.first.severity.name).to eq(:warning)
    end
  end
end
