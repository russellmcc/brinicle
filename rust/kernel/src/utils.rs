use super::event;
use super::AudioBufferMut;

pub enum EventOrAudio<'c, 'a: 'c> {
    Event(event::Event),
    Audio(AudioBufferMut<'c, 'a>),
}

pub fn run_split_at_events<I, F>(mut audio: AudioBufferMut, events: I, mut f: F)
where
    I: Iterator<Item = event::Event>,
    F: FnMut(EventOrAudio),
{
    let buffer_len = audio.len();

    let mut curr_slice_start: usize = 0;
    for ev in events {
        // If the current event time is before or at our "current time";
        // we just handle it and move on.
        if ev.time <= curr_slice_start as i64 {
            f(EventOrAudio::Event(ev));
            continue;
        }

        let time = ev.time as usize;
        assert!(time < buffer_len);

        // We need to handle some audio before we handle the event.
        // Split our AudioBuffer.
        let mut sb = audio.slice(curr_slice_start..time);

        // Process our sub_buffer
        f(EventOrAudio::Audio((&mut sb).into()));

        // update our slice start time.
        curr_slice_start = time;

        // Process the current event.
        f(EventOrAudio::Event(ev));
    }

    // Now handle any remaining audio
    let mut sb = audio.slice(curr_slice_start..buffer_len);
    f(EventOrAudio::Audio((&mut sb).into()));
}
