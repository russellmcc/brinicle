#[warn(nonstandard_style, rust_2018_idioms, future_incompatible)]

pub enum Behavior {
    Omni,
    CableOmni(u8),
    ChannelOmni(u8),
    Specific { cable: u8, channel: u8 },
}

impl Default for Behavior {
    fn default() -> Behavior {
        Behavior::Omni
    }
}

#[derive(Debug)]
pub enum Message {
    NoteOn { note: u8, velocity: u8 },
    NoteOff { note: u8, velocity: u8 },
}

pub fn parse_midi(cable: u8, bytes: &[u8], behavior: Behavior) -> Option<Message> {
    if bytes.is_empty() {
        return None;
    }

    let channel = bytes[0] & 0xF;

    // check if we should short-circuit due to our behavior
    match behavior {
        Behavior::Omni => {}
        Behavior::CableOmni(c) => {
            if c != cable {
                return None;
            }
        }
        Behavior::ChannelOmni(c) => {
            if c != channel {
                return None;
            }
        }
        Behavior::Specific {
            cable: cable_,
            channel: channel_,
        } => {
            if (cable_ != cable) || (channel_ != channel) {
                return None;
            }
        }
    }

    if (bytes[0] & 0xF0 == 0x80) && (bytes.len() == 3) {
        let note = bytes[1];
        let velocity = bytes[2];
        return Some(Message::NoteOff { note, velocity });
    }

    if (bytes[0] & 0xF0 == 0x90) && (bytes.len() == 3) {
        let note = bytes[1];
        let velocity = bytes[2];
        if velocity != 0 {
            return Some(Message::NoteOn { note, velocity });
        } else {
            return Some(Message::NoteOff { note, velocity });
        }
    }

    None
}
