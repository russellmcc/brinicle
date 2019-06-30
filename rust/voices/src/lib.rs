#![warn(nonstandard_style, rust_2018_idioms, future_incompatible)]
use bit_set::BitSet;

/// An interface for one "Voice"
/// in a synth.
pub trait Voice {
    type Configuration: ?Sized;
    fn note_on(&mut self, _: &Self::Configuration, note_number: u8, velocity: u8);
    fn note_off(&mut self, _: &Self::Configuration, velocity: u8);

    /// Returning false here indicates
    /// that the voice is ready for a new note
    /// without audible glitch - i.e.
    /// release is done.
    /// It's legal to return false before
    /// receiving a note_off, but if that
    /// happens a note_off will not be sent.
    fn is_running(&self) -> bool;
}

pub struct Manager {
    num_voices: usize,
    used_voices: Vec<(usize, u8)>,
    free_voices: BitSet,
}

impl Manager {
    pub fn new(num_voices: usize) -> Manager {
        Manager {
            num_voices,
            used_voices: Vec::with_capacity(num_voices),
            free_voices: BitSet::with_capacity(num_voices),
        }
    }

    pub fn note_on<C: Default, V: Voice<Configuration = C>>(
        &mut self,
        voices: &mut [V],
        note_number: u8,
        velocity: u8,
    ) {
        self.note_on_with_config(voices, &V::Configuration::default(), note_number, velocity);
    }

    pub fn note_off<C: Default, V: Voice<Configuration = C>>(
        &mut self,
        voices: &mut [V],
        note_number: u8,
        velocity: u8,
    ) {
        self.note_off_with_config(voices, &V::Configuration::default(), note_number, velocity);
    }

    /// Send a note on to the relevant voice.
    pub fn note_on_with_config<V: Voice>(
        &mut self,
        voices: &mut [V],
        config: &V::Configuration,
        note_number: u8,
        velocity: u8,
    ) {
        assert_eq!(voices.iter().len(), self.num_voices);

        // first, free up any used_voices that are no longer
        // running.  This could be from something like a drum
        // hit that finished itself before a note off.
        self.used_voices
            .retain(|voice_note| voices[voice_note.0].is_running());

        for (i, v) in voices.iter().enumerate() {
            if !v.is_running() {
                self.free_voices.insert(i);
            }
        }

        // get the first free voice.  If there isn't one, drop it.
        let first_free_voice = self.free_voices.iter().next();
        if let Some(i) = first_free_voice {
            self.free_voices.remove(&i);
            voices[i].note_on(config, note_number, velocity);
            self.used_voices.push((i, note_number));
        }
    }

    /// Send a note off to the relevant voice.
    pub fn note_off_with_config<V: Voice>(
        &mut self,
        voices: &mut [V],
        config: &V::Configuration,
        note_number: u8,
        velocity: u8,
    ) {
        assert_eq!(voices.iter().len(), self.num_voices);
        self.used_voices.retain(|voice_note| {
            if voice_note.1 != note_number {
                true
            } else {
                if voices[voice_note.0].is_running() {
                    voices[voice_note.0].note_off(config, velocity);
                }
                false
            }
        });
    }
}
