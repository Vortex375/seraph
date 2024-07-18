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
