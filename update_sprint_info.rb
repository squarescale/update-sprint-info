require 'octokit'

Octokit.default_media_type = "application/vnd.github.inertia-preview+json"
Octokit.auto_paginate = true

client = Octokit::Client.new access_token: ENV['GITHUB_ACCESS_TOKEN']
project_id = ENV['PROJECT_ID']

def no_header(str)
  str.gsub '#', '\\#'
end

types = {
  bug: '⚠ type: bug',
  feature: '✨ type: feature',
  improvement: '⭐ type: improvement',
  tech: '⚒ type: tech'
}

has_labels = -> (issue) { issue.labels }
is_closed = -> (issue) { issue.state == 'closed' }
is_open = -> (issue) { issue.state == 'open' }
is_size_label = -> (label) { label.name.start_with? 'size: ' }
name_to_size = -> (name) { name.gsub('size: ', '').to_i }

size_of_issues = -> (issues) do
  issues.
    map(&:labels).
    compact.
    flatten.
    select(&is_size_label).
    map(&:name).
    map(&name_to_size).
    compact.
    inject(&:+)
end

label_names = -> (issue) { (issue&.labels || []).map(&:name) }

has_mockups = -> (issue) { label_names.call(issue).include?('✅ check: mockups') }
has_test_case = -> (issue) { label_names.call(issue).include?('✅ check: test case') }
approved_on_production = -> (issue) { label_names.call(issue).include?('✅ approved: production') }
approved_on_staging = -> (issue) { label_names.call(issue).include?('✅ approved: staging') }

displayable_row = -> (strings) { strings.join('|').prepend('|').concat('|') }

rules = {
  '📚 Backlog' => [],
  '🔍 Spec' => [],
  '👷 Dev' => [has_mockups, has_test_case],
  '🛴 Staging' => [],
  '🚀 Prod' => [approved_on_staging],
  '✔ Done' => [approved_on_production]
}

limits = {
  '📚 Backlog' => nil,
  '🔍 Spec' => 3,
  '👷 Dev' => 8,
  '🛴 Staging' => 6,
  '🚀 Prod' => 6,
  '✔ Done' => nil
}

output = []

p = {
  cols: [ '**column**' ],
  tasks: [ '**tasks**' ],
  points: [ '**size**' ],
  errors: [ '**warnings**' ],
  limits: [ '**limits**' ],
  total: 0,
  done: 0,
  issues: 0,
  issues_done: 0,
  issue_types: { bug: 0,  feature: 0, improvement: 0, tech: 0 }
}

project = client.project project_id

columns = project.rels[:columns].get.data
columns.each do |col|
  puts "Column #{col.name}"
  p[:cols] <<= col.name
  cards = col.rels[:cards].get.data
  issues = cards.select { |card| card.note.nil? }.map { |card| card.rels[:content].get.data }
  p[:tasks] << issues.length
  limit = limits[col.name]
  limit_ok = if not limit.nil? then issues.length <= limit else true end
  p[:limits] << limit_ok
  p[:issues] += issues.length
  p[:issues_done] += issues.select(&is_closed).length
  size = size_of_issues.call(issues) || 0
  size_done = size_of_issues.call(issues.select(&is_closed)) || 0
  issues_in_error = issues.reject do |issue|
    rules[col.name].map { |rule| rule.call(issue) }.all?
  end
  p[:total] += size
  p[:done] += size_done
  p[:points] <<= size
  p[:errors] <<= issues_in_error.map { |issue| "[##{issue.number}](#{issue.html_url})" }.join(" - ")

  issues.each do |issue|
    labels = label_names.call(issue)
    types.each do |type, label|
      if labels.include? label
        p[:issue_types][type] += 1
      end
    end
  end

  notes = cards.select { |card| !card.note.nil? }
  note = notes.first
  status = []
  status << "**Points** `#{size}`"
  task_status = "**Tasks** `#{issues.length}"
  unless limit.nil?
    task_status += "/#{limit}"
  end
  task_status += "`"
  status << task_status
  unless limit_ok
    status << ""
    status << "**Limit exceeded by #{issues.length - limit}**"
    status << ""
  end
  unless issues_in_error.empty?
    status << ""
    status << "*Issues with warnings:*"
    status << ""
    status.concat(issues_in_error.map { |issue| "- ##{issue.number}" })
  end
  client.update_project_card(note.id, note: status.join("\n"))
end

lines = project.body.split(/\r?\n/)
start_details = lines.index('<details>')
end_details = lines.index('</details>')
details = lines[(start_details + 2)...end_details]
start_date = details[0]
end_date = details[1]
initial_nb_tasks = details.length > 2 ? details[2] : p[:issues]
initial_points = details.length > 3 ? details [3] : size
days = []
today = Time.now.strftime('%F')
if details.length > 5
  days.concat(details.last(details.length - 5))
  last_details = days.last.split(',')
  if last_details.first == today
    days.pop
  end
end
days << [today].concat(p[:tasks]).concat(p[:points]).concat(p[:errors]).concat(p[:limits]).join(',')
days.unshift(['date'].concat(p[:cols]).concat(p[:cols]).concat(p[:cols]).concat(p[:cols]).join(','))

output << '|Start date   |End date   |'
output << '|-------------|-----------|'
output << "|#{start_date}|#{end_date}|"
output << ''

output << '### Tasks'
output << ''
output << '|Initial            |Total        |Done              |'
output << '|-------------------|-------------|------------------|'
output << "|#{initial_nb_tasks}|#{p[:issues]}|#{p[:issues_done]}|"
output << ''

output << '### Points'
output << ''
output << '|Initial          |Total       |Done       |'
output << '|-----------------|------------|-----------|'
output << "|#{initial_points}|#{p[:total]}|#{p[:done]}|"
output << ''

issue_types = p[:issue_types]
output << '### Types'
output << ''
output << '|Feature                 |Improvement                 |Bug                 |Tech                 |'
output << '|------------------------|----------------------------|--------------------|---------------------|'
output << "|#{issue_types[:feature]}|#{issue_types[:improvement]}|#{issue_types[:bug]}|#{issue_types[:tech]}|"
output << ''

output << displayable_row.call(p[:cols].last(p[:cols].length - 1).unshift(''))
output << displayable_row.call(Array.new(p[:cols].size, '---'))
output << displayable_row.call(p[:tasks])
output << displayable_row.call(p[:points])
output << displayable_row.call(p[:errors])
output << displayable_row.call(p[:limits]).gsub('true', '').gsub('false', 'TOO MANY ITEMS')

output << ''

output << '<details>'
output << '<summary>Details</summary>'

output << start_date
output << end_date
output << initial_nb_tasks
output << initial_points

days.each do |day|
  output << day
end

output << '</details>'

client.update_project project_id, body: output.join("\n")

