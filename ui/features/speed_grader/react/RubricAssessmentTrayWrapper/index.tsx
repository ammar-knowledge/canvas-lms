/*
 * Copyright (C) 2024 - present Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License along
 * with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import React from 'react'
import {RubricAssessmentTray} from '@canvas/rubrics/react/RubricAssessment'
import useStore from '../../stores'
import type {RubricAssessmentData} from '@canvas/rubrics/react/types/rubric'
import {
  mapRubricAssessmentDataUnderscoredKeysToCamelCase,
  mapRubricUnderscoredKeysToCamelCase,
  type RubricOutcomeUnderscore,
  type RubricUnderscoreType,
} from './utils'

const convertSubmittedAssessment = (assessments: RubricAssessmentData[]): any => {
  const {assessment_user_id, anonymous_id, assessment_type} = ENV.RUBRIC_ASSESSMENT ?? {}

  const data: {[key: string]: string | undefined | number} = {}
  if (assessment_user_id) {
    data['rubric_assessment[user_id]'] = assessment_user_id
  } else {
    data['rubric_assessment[anonymous_id]'] = anonymous_id
  }

  data['rubric_assessment[assessment_type]'] = assessment_type

  assessments.forEach(assessment => {
    const pre = `rubric_assessment[criterion_${assessment.criterionId}]`
    data[pre + '[points]'] = assessment.points
    data[pre + '[comments]'] = assessment.comments
    data[pre + '[save_comment]'] = assessment.saveCommentsForLater ? '1' : '0'
    data[pre + '[description]'] = assessment.description
    if (assessment.id) {
      data[pre + '[rating_id]'] = assessment.id
    }
  })

  return data
}

type RubricAssessmentTrayWrapperProps = {
  rubric: RubricUnderscoreType
  rubricOutcomeData?: RubricOutcomeUnderscore[]
  onAccessorChange: (assessorId: string) => void
  onSave: (assessmentData: any) => void
}
export default ({
  rubric,
  rubricOutcomeData,
  onAccessorChange,
  onSave,
}: RubricAssessmentTrayWrapperProps) => {
  const {
    rubricAssessmentTrayOpen,
    studentAssessment,
    rubricAssessors,
    rubricHidePoints,
    rubricSavedComments = {},
  } = useStore()

  const handleSubmit = (assessmentData: RubricAssessmentData[]) => {
    const data = convertSubmittedAssessment(assessmentData)
    onSave(data)
  }

  const isPreviewPeerMode =
    !!studentAssessment?.assessor_id &&
    studentAssessment.assessor_id !== ENV.RUBRIC_ASSESSMENT?.assessor_id

  return (
    <RubricAssessmentTray
      hidePoints={rubricHidePoints}
      isOpen={rubricAssessmentTrayOpen}
      isPreviewMode={isPreviewPeerMode}
      isPeerReview={isPreviewPeerMode}
      rubric={mapRubricUnderscoredKeysToCamelCase(rubric, rubricOutcomeData)}
      rubricAssessmentData={mapRubricAssessmentDataUnderscoredKeysToCamelCase(
        studentAssessment?.data ?? []
      )}
      rubricAssessmentId={studentAssessment?.id}
      rubricAssessors={rubricAssessors}
      rubricSavedComments={rubricSavedComments}
      onAccessorChange={onAccessorChange}
      onDismiss={() => useStore.setState({rubricAssessmentTrayOpen: false})}
      onSubmit={handleSubmit}
    />
  )
}
