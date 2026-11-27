///|
priv enum SeriesSlot {
  IntSlot(Int32)
  DoubleSlot(Int32)
  HistogramSlot(Int32)
  ExponentialSlot(Int32)
}

///|
// Private derived data only. Checkpoint wire formats remain unchanged.
fn indexed_state(
  records : Array[Record],
  doubles : Array[DoubleRecord],
  histograms : Array[HistogramRecord],
  limit : Int32,
  exponentials~ : Array[ExponentialRecord] = [],
) -> State {
  let index : Map[String, SeriesSlot] = Map([])
  for i, r in records {
    index[r.last.series] = IntSlot(i)
  }
  for i, r in doubles {
    index[r.last.series] = DoubleSlot(i)
  }
  for i, r in histograms {
    index[r.last_hist.series] = HistogramSlot(i)
  }
  for i, r in exponentials {
    index[r.last_exp.series] = ExponentialSlot(i)
  }
  { records, doubles, histograms, exponentials, limit, index, }
}

///|
// Only private request transactions may mutate these detached arrays/index.
fn State::detached(self : State) -> State {
  {
    records: self.records.copy(),
    doubles: self.doubles.copy(),
    histograms: self.histograms.copy(),
    exponentials: self.exponentials.copy(),
    index: self.index.copy(),
    limit: self.limit,
  }
}
