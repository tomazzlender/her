# frozen_string_literal: true

require_relative "config/boot"
require "sinatra/base"

class DemoApp < Sinatra::Base
  PROJECTS = [
    { id: 1, name: "HER",         stars: 4200, archived: false },
    { id: 2, name: "Old & Dusty", stars: 3,    archived: true }
  ].freeze

  configure do
    # Every component call written in the templates checks out, or we
    # refuse to boot — the same gate as `her check -r config/boot.rb`.
    Her.verify!(UI)
  end

  before do
    # The dev loop: edit any .html.her (markup OR its frontmatter
    # contract) and the next request picks it up — no Ruby reload needed.
    Her.reload_templates!(UI) if settings.development?
  end

  get "/" do
    UI.projects_page(projects: PROJECTS).to_s
  end

  get "/empty" do
    UI.projects_page(projects: []).to_s
  end
end
