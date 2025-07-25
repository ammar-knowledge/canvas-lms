//
// Copyright (C) 2011 - present Instructure, Inc.
//
// This file is part of Canvas.
//
// Canvas is free software: you can redistribute it and/or modify it under
// the terms of the GNU Affero General Public License as published by the Free
// Software Foundation, version 3 of the License.
//
// Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
// A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
// details.
//
// You should have received a copy of the GNU Affero General Public License along
// with this program. If not, see <http://www.gnu.org/licenses/>.

import $ from 'jquery'
import Backbone from '@canvas/backbone'
import userSettings from '@canvas/user-settings'
import OutcomeSummaryCollection from './backbone/collections/OutcomeSummaryCollection'
import OutcomeSummaryView from './backbone/views/OutcomeSummaryView'
import IndividualStudentView from './backbone/views/IndividualStudentView'
import GradeSummary from './jquery/index'
import 'jqueryui/tabs'
import '@canvas/jquery/jquery.disableWhileLoading'

$(() => {
  // Ensure the gradebook summary code has had a chance to setup all its handlers
  GradeSummary.setup()

  let router
  class GradebookSummaryRouter extends Backbone.Router {
    initialize() {
      if (!ENV.student_outcome_gradebook_enabled) return
      $('#content').tabs({activate: this.activate})

      const course_id = ENV.context_asset_string.replace('course_', '')
      const user_id = ENV.student_id

      if (ENV.gradebook_non_scoring_rubrics_enabled) {
        this.outcomeView = new IndividualStudentView({
          el: $('#outcomes'),
          course_id,
          student_id: user_id,
        })
      } else {
        this.outcomes = new OutcomeSummaryCollection([], {course_id, user_id})
        this.outcomeView = new OutcomeSummaryView({
          el: $('#outcomes'),
          collection: this.outcomes,
          toggles: $('.outcome-toggles'),
        })
      }
    }

    tab(tab, path) {
      if (tab !== 'outcomes' && tab !== 'assignments') {
        tab = userSettings.contextGet('grade_summary_tab') || 'assignments'
      }
      $(`a[href='#${tab}']`).click()
      if (tab === 'outcomes') {
        if (!this.outcomeView) return
        this.outcomeView.show(path)
        $('.outcome-toggles').show()
      } else {
        $('.outcome-toggles').hide()
      }
    }

    activate(event, ui) {
      const tab = ui.newPanel.attr('id')
      router.navigate(`#tab-${tab}`, {trigger: true})
      return userSettings.contextSet('grade_summary_tab', tab)
    }
  }
  GradebookSummaryRouter.prototype.routes = {
    '': 'tab',
    'tab-:route(/*path)': 'tab',
  }

  GradeSummary.renderSelectMenuGroup()
  GradeSummary.renderSubmissionCommentsTray()
  if (ENV.student_grade_summary_upgrade || ENV.restrict_quantitative_data) {
    GradeSummary.renderGradeSummaryTable()
  } else {
    GradeSummary.addAssetProcessorToLegacyTable()
  }
  if (ENV.can_clear_badge_counts) {
    GradeSummary.renderClearBadgeCountsButton()
  }

  router = new GradebookSummaryRouter()
  Backbone.history.start()
})
