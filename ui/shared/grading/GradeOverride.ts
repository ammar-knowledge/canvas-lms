/*
 * Copyright (C) 2018 - present Instructure, Inc.
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

export default class GradeOverride {
  _attr: {
    percentage: number | null
    schemeKey: string | null
  }

  constructor(attr: {percentage?: number | null; schemeKey?: string | null}) {
    this._attr = {
      percentage: null,
      schemeKey: null,
      ...attr,
    }
  }

  get percentage() {
    return this._attr.percentage
  }

  get schemeKey() {
    return this._attr.schemeKey
  }

  // @ts-expect-error
  equals(gradeOverride) {
    return (
      this.percentage === gradeOverride.percentage && this.schemeKey === gradeOverride.schemeKey
    )
  }
}
