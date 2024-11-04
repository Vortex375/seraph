// Copyright © 2024 Benjamin Schmitz

// This file is part of Seraph <https://github.com/Vortex375/seraph>.

// Seraph is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License
// as published by the Free Software Foundation,
// either version 3 of the License, or (at your option)
// any later version.

// Seraph is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.

// You should have received a copy of the GNU Affero General Public License
// along with Seraph.  If not, see <http://www.gnu.org/licenses/>.

package entities

type Definable[T any] struct {
	Value   T
	Defined bool
}

func (d *Definable[T]) Set(value T) {
	d.Value = value
	d.Defined = true
}

func (d *Definable[T]) Unset() {
	var null T
	d.Value = null
	d.Defined = false
}

func (d *Definable[T]) Get() T {
	return d.Value
}

func (d *Definable[T]) IsDefined() bool {
	return d.Defined
}

func (d Definable[T]) getInternal() (any, bool) {
	return d.Value, d.Defined
}

type definableInternal interface {
	getInternal() (any, bool)
}
