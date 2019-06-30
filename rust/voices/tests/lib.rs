use brinicle_voices::*;

#[derive(Default)]
struct Configuration;

struct MockVoice {
    note_on_calls: Vec<(u8, u8)>,
    note_off_calls: Vec<u8>,

    is_running: bool,
}

impl Voice for MockVoice {
    type Configuration = Configuration;
    fn note_on(&mut self, _: &Configuration, note_number: u8, velocity: u8) {
        self.is_running = true;
        self.note_on_calls.push((note_number, velocity));
    }
    fn note_off(&mut self, _: &Configuration, velocity: u8) {
        self.is_running = false;
        self.note_off_calls.push(velocity);
    }

    fn is_running(&self) -> bool {
        return self.is_running;
    }
}

impl Default for MockVoice {
    fn default() -> MockVoice {
        return MockVoice {
            note_on_calls: Vec::new(),
            note_off_calls: Vec::new(),
            is_running: false,
        };
    }
}

#[test]
fn note_on_off_gets_called() {
    let mut mock = vec![MockVoice::default()];
    let mut manager = Manager::new(1);
    manager.note_on(&mut mock[..], 32, 88);
    manager.note_off(&mut mock[..], 32, 89);
    assert_eq!(mock[0].note_on_calls.len(), 1);
    assert_eq!(mock[0].note_on_calls[0], (32, 88));
    assert_eq!(mock[0].note_off_calls.len(), 1);
    assert_eq!(mock[0].note_off_calls[0], 89);
}

#[test]
fn note_off_gets_called_once() {
    let mut mock = vec![MockVoice::default()];
    let mut manager = Manager::new(1);
    manager.note_on(&mut mock[..], 32, 88);
    manager.note_off(&mut mock[..], 32, 89);
    manager.note_off(&mut mock[..], 32, 89);
    assert_eq!(mock[0].note_on_calls.len(), 1);
    assert_eq!(mock[0].note_on_calls[0], (32, 88));
    assert_eq!(mock[0].note_off_calls.len(), 1);
    assert_eq!(mock[0].note_off_calls[0], (89));
}

#[test]
fn note_off_does_not_get_called() {
    let mut mock = vec![MockVoice::default()];
    let mut manager = Manager::new(1);
    manager.note_on(&mut mock[..], 32, 88);
    manager.note_off(&mut mock[..], 33, 89);
    assert_eq!(mock[0].note_on_calls.len(), 1);
    assert_eq!(mock[0].note_on_calls[0], (32, 88));
    assert_eq!(mock[0].note_off_calls.len(), 0);
}

#[test]
fn notes_distributed() {
    let mut mock = vec![MockVoice::default(), MockVoice::default()];
    let mut manager = Manager::new(2);
    manager.note_on(&mut mock[..], 32, 88);
    manager.note_on(&mut mock[..], 33, 88);
    manager.note_off(&mut mock[..], 33, 89);
    manager.note_off(&mut mock[..], 32, 89);
    assert_eq!(mock[0].note_on_calls.len(), 1);
    assert_eq!(mock[0].note_on_calls[0], (32, 88));
    assert_eq!(mock[0].note_off_calls.len(), 1);
    assert_eq!(mock[0].note_off_calls[0], 89);
    assert_eq!(mock[1].note_on_calls.len(), 1);
    assert_eq!(mock[1].note_on_calls[0], (33, 88));
    assert_eq!(mock[1].note_off_calls.len(), 1);
    assert_eq!(mock[1].note_off_calls[0], 89);
}

#[test]
fn first_voice_repeats() {
    let mut mock = vec![MockVoice::default(), MockVoice::default()];
    let mut manager = Manager::new(2);
    manager.note_on(&mut mock[..], 32, 88);
    manager.note_off(&mut mock[..], 32, 89);
    manager.note_on(&mut mock[..], 33, 88);
    manager.note_off(&mut mock[..], 33, 89);
    assert_eq!(mock[0].note_on_calls.len(), 2);
    assert_eq!(mock[0].note_off_calls.len(), 2);
    assert_eq!(mock[1].note_on_calls.len(), 0);
    assert_eq!(mock[1].note_off_calls.len(), 0);
}

#[test]
fn repeat_note_on() {
    let mut mock = vec![MockVoice::default(), MockVoice::default()];
    let mut manager = Manager::new(2);
    manager.note_on(&mut mock[..], 32, 88);
    mock[0].is_running = false;
    manager.note_on(&mut mock[..], 33, 88);
    assert_eq!(mock[0].note_on_calls.len(), 2);
    assert_eq!(mock[1].note_on_calls.len(), 0);
}

#[test]
fn no_note_off_if_self_ended() {
    let mut mock = vec![MockVoice::default(), MockVoice::default()];
    let mut manager = Manager::new(2);
    manager.note_on(&mut mock[..], 32, 88);
    mock[0].is_running = false;
    manager.note_off(&mut mock[..], 32, 88);
    assert_eq!(mock[0].note_on_calls.len(), 1);
    assert_eq!(mock[0].note_off_calls.len(), 0);
}
