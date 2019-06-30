#[warn(nonstandard_style, rust_2018_idioms, future_incompatible)]
pub trait Scale {
    fn to_frequency(&self, note_number: f32) -> f32;
}

pub struct EqualTemperament {
    freq_for_note_69: f32,
}

impl Scale for EqualTemperament {
    fn to_frequency(&self, note_number: f32) -> f32 {
        let offset = note_number - 69f32;
        self.freq_for_note_69 * 2f32.powf(offset / 12.)
    }
}

impl Default for EqualTemperament {
    fn default() -> EqualTemperament {
        EqualTemperament {
            freq_for_note_69: 440f32,
        }
    }
}

impl EqualTemperament {
    pub fn new(concert_a: f32) -> EqualTemperament {
        EqualTemperament {
            freq_for_note_69: concert_a,
        }
    }
}
