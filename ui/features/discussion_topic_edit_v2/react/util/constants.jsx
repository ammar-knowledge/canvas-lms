/*
 * Copyright (C) 2023 - present Instructure, Inc.
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
import {useScope as createI18nScope} from '@canvas/i18n'

const I18n = createI18nScope('discussion_create')

export const defaultEveryoneOption = {
  assetCode: 'everyone',
  label: I18n.t('Everyone'),
}
export const defaultEveryoneElseOption = {
  assetCode: 'everyone',
  label: I18n.t('Everyone else'),
}

export const masteryPathsOption = {
  assetCode: 'mastery_paths',
  label: I18n.t('Mastery Paths'),
}

const DiscussionDueDateDefaultValues = {
  assignedInfoList: [],
  setAssignedInfoList: () => {},
  studentEnrollments: [],
  sections: [],
  groups: [],
  gradedDiscussionRefMap: new Map(),
  setGradedDiscussionRefMap: () => {},
  pointsPossibleReplyToTopic: 0,
  setPointsPossibleReplyToTopic: points => {},
  pointsPossibleReplyToEntry: 0,
  setPointsPossibleReplyToEntry: points => {},
  replyToEntryRequiredCount: 1,
  setReplyToEntryRequiredCount: count => {},
  importantDates: false,
  setImportantDates: newImportantDatesValue => {},
}

export const DiscussionDueDatesContext = React.createContext(DiscussionDueDateDefaultValues)

export const ASSIGNMENT_OVERRIDE_GRAPHQL_TYPENAMES = {
  ADHOC: 'AdhocStudents',
  SECTION: 'Section',
  GROUP: 'Group',
  COURSE: 'Course',
}

export const minimumReplyToEntryRequiredCount = 1
export const maximumReplyToEntryRequiredCount = 10

export const REPLY_TO_TOPIC = 'reply_to_topic'
export const REPLY_TO_ENTRY = 'reply_to_entry'

export const DEFAULT_SORT_ORDER = 'asc'
export const DEFAULT_SORT_ORDER_LOCKED = false
export const DEFAULT_EXPANDED_STATE = true
export const DEFAULT_EXPANDED_LOCKED = false

export const useShouldShowContent = (
  isGraded,
  isAnnouncement,
  isGroupDiscussion,
  isGroupContext,
  discussionAnonymousState,
  isEditing,
  isStudent,
  published,
  isCheckpoints,
  isAlreadyAGroupDiscussion,
) => {
  const shouldShowTodoSettings =
    !isGraded &&
    !isAnnouncement &&
    ENV.DISCUSSION_TOPIC?.PERMISSIONS?.CAN_MANAGE_CONTENT &&
    ENV.STUDENT_PLANNER_ENABLED

  const shouldShowPostToSectionOption =
    !isGraded && !isGroupDiscussion && !isGroupContext && isAnnouncement

  const shouldShowAnonymousOptions =
    !isGroupContext &&
    !isAnnouncement &&
    (ENV.DISCUSSION_TOPIC?.PERMISSIONS?.CAN_MODERATE ||
      ENV.allow_student_anonymous_discussion_topics)

  const shouldShowViewSettings = ENV.DISCUSSION_TOPIC?.PERMISSIONS?.CAN_MODERATE && !isAnnouncement

  const shouldShowGroupOptions =
    !isAnnouncement && !isGroupContext && ENV.DISCUSSION_TOPIC.PERMISSIONS.CAN_SET_GROUP

  const shouldShowGradedDiscussionOptions =
    !isAnnouncement && !isGroupContext && ENV.DISCUSSION_TOPIC.PERMISSIONS.CAN_CREATE_ASSIGNMENT

  const shouldShowUsageRightsOption =
    ENV?.DISCUSSION_TOPIC?.PERMISSIONS?.CAN_ATTACH && ENV?.USAGE_RIGHTS_REQUIRED

  const shouldShowLikingOption = !ENV.K5_HOMEROOM_COURSE

  const shouldShowPartialAnonymousSelector =
    !isEditing && discussionAnonymousState === 'partial_anonymity' && isStudent

  const shouldShowAvailabilityOptions = !isGroupContext

  /* discussion moderators viewing a new or still unpublished discussion */
  const shouldShowSaveAndPublishButton =
    !isAnnouncement && ENV.DISCUSSION_TOPIC?.PERMISSIONS?.CAN_MODERATE && !published

  const shouldShowPodcastFeedOption =
    ENV.DISCUSSION_TOPIC?.PERMISSIONS?.CAN_MODERATE && !ENV.K5_HOMEROOM_COURSE

  const shouldShowCheckpointsOptions =
    isGraded && ENV.DISCUSSION_CHECKPOINTS_ENABLED && !ENV.RESTRICT_QUANTITATIVE_DATA

  const shouldShowAssignToForUngradedDiscussions =
    !isAnnouncement && !isGraded && ENV.DISCUSSION_TOPIC?.PERMISSIONS?.CAN_MANAGE_ASSIGN_TO_UNGRADED

  const shouldShowAllowParticipantsToCommentOption =
    !ENV?.ANNOUNCEMENTS_COMMENTS_DISABLED && isAnnouncement

  const groupContextType = ENV?.GROUP_CONTEXT_TYPE

  const shouldShowSuppressAssignmentOption = isGraded && ENV.SETTINGS.suppress_assignments

  return {
    shouldShowTodoSettings,
    shouldShowPostToSectionOption,
    shouldShowAnonymousOptions,
    shouldShowViewSettings,
    shouldShowGroupOptions,
    shouldShowGradedDiscussionOptions,
    shouldShowUsageRightsOption,
    shouldShowLikingOption,
    shouldShowPartialAnonymousSelector,
    shouldShowAvailabilityOptions,
    shouldShowSaveAndPublishButton,
    shouldShowPodcastFeedOption,
    shouldShowCheckpointsOptions,
    shouldShowAssignToForUngradedDiscussions,
    shouldShowAllowParticipantsToCommentOption,
    shouldShowSuppressAssignmentOption,
    groupContextType,
  }
}
