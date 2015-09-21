#-- copyright
# OpenProject Backlogs Plugin
#
# Copyright (C)2013-2014 the OpenProject Foundation (OPF)
# Copyright (C)2011 Stephan Eckardt, Tim Felgentreff, Marnen Laibow-Koser, Sandro Munda
# Copyright (C)2010-2011 friflaj
# Copyright (C)2010 Maxime Guilbot, Andrew Vit, Joakim Kolsjö, ibussieres, Daniel Passos, Jason Vasquez, jpic, Emiliano Heyns
# Copyright (C)2009-2010 Mark Maglana
# Copyright (C)2009 Joe Heck, Nate Lowrie
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License version 3.
#
# OpenProject Backlogs is a derivative work based on ChiliProject Backlogs.
# The copyright follows:
# Copyright (C) 2010-2011 - Emiliano Heyns, Mark Maglana, friflaj
# Copyright (C) 2011 - Jens Ulferts, Gregor Schmidt - Finn GmbH - Berlin, Germany
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See doc/COPYRIGHT.rdoc for more details.
#++

class Story < WorkPackage
  extend OpenProject::Backlogs::Mixins::PreventIssueSti

  def self.backlogs(project_id, sprint_ids, options = {})
    options.reverse_merge!(order: Story::ORDER,
                           conditions: Story.condition(project_id, sprint_ids))

    candidates = Story.where(options[:conditions]).order(options[:order])

    stories_by_version = Hash.new do |hash, sprint_id|
      hash[sprint_id] = []
    end

    candidates.each do |story|
      last_rank = stories_by_version[story.fixed_version_id].size > 0 ?
                     stories_by_version[story.fixed_version_id].last.rank :
                     0

      story.rank = last_rank + 1
      stories_by_version[story.fixed_version_id] << story
    end

    stories_by_version
  end

  def self.sprint_backlog(project, sprint, options = {})
    Story.backlogs(project.id, [sprint.id], options)[sprint.id]
  end

  def self.create_and_position(params, safer_attributes)
    Story.new.tap do |s|
      s.author  = safer_attributes[:author]  if safer_attributes[:author]
      s.project = safer_attributes[:project] if safer_attributes[:project]
      s.safe_attributes = params

      if s.save
        s.move_after(params['prev_id'])
      end
    end
  end

  def self.at_rank(project_id, sprint_id, rank)
    Story.where(Story.condition(project_id, sprint_id))
         .joins(:status)
         .order(Story::ORDER)
         .offset(rank -1)
         .first
  end

  def self.types
    types = Setting.plugin_openproject_backlogs['story_types']
    return [] if types.blank?

    types.map { |type| Integer(type) }
  end

  def tasks
    Task.tasks_for(id)
  end

  def tasks_and_subtasks
    return [] unless Task.type
    descendants.where(type_id: Task.type)
  end

  def direct_tasks_and_subtasks
    return [] unless Task.type
    children.where(type_id: Task.type).map { |t| [t] + t.descendants }.flatten
  end

  def set_points(p)
    init_journal(User.current)

    if p.blank? || p == '-'
      update_attribute(:story_points, nil)
      return
    end

    if p.downcase == 's'
      update_attribute(:story_points, 0)
      return
    end

    p = Integer(p)
    if p >= 0
      update_attribute(:story_points, p)
      return
    end
  end

  # TODO: Refactor and add tests
  #
  # groups = tasks.partion(&:closed?)
  # {:open => tasks.last.size, :closed => tasks.first.size}
  #
  def task_status
    closed = 0
    open = 0

    tasks.each do |task|
      if task.closed?
        closed += 1
      else
        open += 1
      end
    end

    { open: open, closed: closed }
  end

  def update_and_position!(params)
    self.safe_attributes = params
    self.status_id = nil if params[:status_id] == ''

    save.tap do |result|
      if result and params[:prev]
        reload
        move_after(params[:prev])
      end
    end
  end

  def rank=(r)
    @rank = r
  end

  def rank
    if position.blank?
      extras = ["and ((#{WorkPackage.table_name}.position is NULL and #{WorkPackage.table_name}.id <= ?) or not #{WorkPackage.table_name}.position is NULL)", id]
    else
      extras = ["and not #{WorkPackage.table_name}.position is NULL and #{WorkPackage.table_name}.position <= ?", position]
    end

    @rank ||= WorkPackage.where(Story.condition(project.id, fixed_version_id, extras))
              .joins(:status)
              .count
    @rank
  end

  private

  def self.condition(project_id, sprint_ids, extras = [])
    project = Project.find(project_id)
    project_ids = project.hierarchy().map(&:id)
    c = ['project_id in (?) AND type_id in (?) AND fixed_version_id in (?)',
         project_ids, Story.types, sprint_ids]

    if extras.size > 0
      c[0] += ' ' + extras.shift
      c += extras
    end

    c
  end

  # This forces NULLS-LAST ordering
  ORDER = "CASE WHEN #{WorkPackage.table_name}.position IS NULL THEN 1 ELSE 0 END ASC, CASE WHEN #{WorkPackage.table_name}.position IS NULL THEN #{WorkPackage.table_name}.id ELSE #{WorkPackage.table_name}.position END ASC"
end
