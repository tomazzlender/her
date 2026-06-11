# frozen_string_literal: true

# A complete page, the way a real app composes one: a layout component with
# slots, a nav, a data-driven card grid, and a form built with a capture
# helper — finishing with boot-time verification.
#
#   ruby -Ilib examples/07_full_page.rb

require "her"

module Site
  extend Her::Component

  # -- layout ------------------------------------------------------------------

  component :layout do
    attr :title, :string, required: true
    template <<~'HER'
      <!DOCTYPE html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>{@title}</title>
          <style>body { font-family: system-ui; margin: 2rem }</style>
        </head>
        <body>
          <header>
            <:nav>
              <nav><a href="/">Home</a></nav>
            </:nav>
          </header>
          <main>{render_slot(:inner)}</main>
          <footer><:footer>© Example Corp</:footer></footer>
        </body>
      </html>
    HER
  end

  component :nav_link do
    attr :href,    :string, required: true
    attr :label,   :string, required: true
    attr :current, :boolean, default: false
    template <<~'HER'
      <a href={@href} aria-current={@current && "page"}>{@label}</a>
    HER
  end

  # -- content ------------------------------------------------------------------

  component :project_card do
    attr :project, :hash, required: true
    attr :rest, :global
    template <<~'HER'
      <article class="card" {@rest}>
        <h2>{@project[:name]}</h2>
        {if @project[:archived]}
          <p><em>archived</em></p>
        {else}
          <p>{@project[:stars]} ★</p>
        {end}
        <.nav_link href={"/projects/#{@project[:id]}"} label="Open"/>
      </article>
    HER
  end

  component :project_grid do
    attr :projects, :array, required: true
    template <<~'HER'
      {if @projects.empty?}
        <p>No projects yet.</p>
      {else}
        <div class="grid">
          {@projects.each do |project|}
            <.project_card project={project} data-id={project[:id]}/>
          {end}
        </div>
      {end}
    HER
  end

  # -- form, via a capture helper --------------------------------------------------

  def self.form(action)
    Her.raw(%(<form action="#{Her.safe(action)}" method="post">#{Her.safe(yield)}</form>))
  end

  component :new_project_form do
    template <<~'HER'
      {= form("/projects") do}
        <label>Name <input name="name" required></label>
        <button type="submit">Create</button>
      {end}
    HER
  end

  # -- the page ----------------------------------------------------------------------

  component :projects_page do
    attr :projects, :array, required: true
    template <<~'HER'
      <.layout title="Projects — Example & Co">
        <:nav>
          <nav>
            <.nav_link href="/" label="Home"/>
            <.nav_link href="/projects" label="Projects" current/>
          </nav>
        </:nav>
        <h1>Projects</h1>
        <.project_grid projects={@projects}/>
        <h2>New project</h2>
        <.new_project_form/>
        <:footer>Made with HER</:footer>
      </.layout>
    HER
  end
end

# Every call site above — components, attrs, types, slots — checks at boot:
Her.verify!(Site)

projects = [
  { id: 1, name: "HER",          stars: 4200, archived: false },
  { id: 2, name: "Old & Dusty",  stars: 3,    archived: true }
]

puts Site.projects_page(projects: projects)
