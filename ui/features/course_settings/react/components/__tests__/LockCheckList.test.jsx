/*
 * Copyright (C) 2017 - present Instructure, Inc.
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
import * as enzyme from 'enzyme'
import LockCheckList from '../LockCheckList'

const ok = value => expect(value).toBeTruthy()
const equal = (value, expected) => expect(value).toEqual(expected)
const deepEqual = (value, expected) => expect(value).toEqual(expected)

const defaultProps = () => ({
  locks: {
    content: false,
    points: false,
    due_dates: false,
    availability_dates: false,
  },
  lockableAttributes: ['content', 'points', 'due_dates', 'availability_dates'],
  formName: '[blueprint_restrictions_by_object_type]',
})

describe('LockCheckList component', () => {
  test('renders the LockCheckList', () => {
    const tree = enzyme.shallow(<LockCheckList {...defaultProps()} />)
    const node = tree.find('.bcs_check_box-group')
    ok(node.exists())
  })

  test('renders the appropriate amount of Checkboxes', () => {
    const props = defaultProps()
    props.lockableAttributes = ['content', 'points']
    const tree = enzyme.shallow(<LockCheckList {...props} />)
    const node = tree.find('.bcs_check_box-group')
    equal(node.length, 2)
  })

  test('selecting checkbox calls onChange', done => {
    const props = defaultProps()
    props.onChange = jest.fn()
    const tree = enzyme.shallow(<LockCheckList {...props} />)
    const checkbox = tree.find('.bcs_check_box-group Checkbox')
    checkbox.at(0).simulate('change', {
      target: {
        checked: true,
      },
    })
    setTimeout(() => {
      expect(props.onChange).toHaveBeenCalledTimes(1)
      expect(props.onChange).toHaveBeenCalledWith({
        content: true,
        points: false,
        due_dates: false,
        availability_dates: false,
      })
      done()
    }, 0)
  })
})
