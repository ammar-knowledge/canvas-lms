/*
 * Copyright (C) 2021 - present Instructure, Inc.
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
import React, {useMemo} from 'react'
import {keyBy} from 'lodash'
import {View} from '@instructure/ui-view'
import {Flex} from '@instructure/ui-flex'
import {StudentOutcomeScore} from './StudentOutcomeScore'
import {Student, Outcome, StudentRollupData, OutcomeRollup} from '../../types/rollup'
import {COLUMN_WIDTH, COLUMN_PADDING, CELL_HEIGHT} from '../../utils/constants'

export interface ScoresGridProps {
  students: Student[]
  outcomes: Outcome[]
  rollups: StudentRollupData[]
}

interface ExtendedOutcomeRollup extends OutcomeRollup {
  studentId: string | number
}

export const ScoresGrid: React.FC<ScoresGridProps> = ({students, outcomes, rollups}) => {
  const rollupsByStudentAndOutcome = useMemo(() => {
    const outcomeRollups = rollups.flatMap(r =>
      r.outcomeRollups.map(or => ({
        studentId: r.studentId,
        ...or,
      })),
    ) as ExtendedOutcomeRollup[]

    return keyBy(outcomeRollups, ({studentId, outcomeId}) => `${studentId}_${outcomeId}`)
  }, [rollups])

  return (
    <Flex direction="column">
      {students.map(student => (
        <Flex direction="row" key={student.id}>
          {outcomes.map((outcome, index) => (
            <Flex.Item
              size={`${COLUMN_WIDTH + COLUMN_PADDING}px`}
              key={`${student.id}${outcome.id}${index}`}
              data-testid={`student-outcome-score-${student.id}-${outcome.id}`}
            >
              <View
                as="div"
                height={CELL_HEIGHT}
                borderWidth="0 0 small 0"
                width={COLUMN_WIDTH}
                overflowX="auto"
              >
                <StudentOutcomeScore
                  rollup={rollupsByStudentAndOutcome[`${student.id}_${outcome.id}`]}
                  outcome={outcome}
                />
              </View>
            </Flex.Item>
          ))}
        </Flex>
      ))}
    </Flex>
  )
}
