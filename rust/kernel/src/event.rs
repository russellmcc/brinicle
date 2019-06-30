#[derive(Debug)]
pub enum Data {
    ParameterChange {
        address: u64,
        value: f64,
    },
    RampedParameterChange {
        address: u64,
        value: f64,
        ramp_time: u32,
    },
    MIDIMessage {
        cable: u8,
        valid_bytes: u16,
        bytes: [u8; 3],
    },
}

#[derive(Debug)]
pub struct Event {
    // time is represented as samples from the buffer start.
    pub time: i64,
    pub data: Data,
}
