#[derive(Clone, Copy)]
pub struct AudioFormat {
    pub input_channel_count: u32,
    pub output_channel_count: u32,
    pub sample_rate: f64,
}

#[derive(Clone, Copy)]
pub enum AllowedChannels {
    AnyChannelCountAllowed,
    ChannelCountAllowed(u32),
}

#[derive(Clone, Copy)]
pub struct AllowedFormat {
    pub input_channels: AllowedChannels,
    pub output_channels: AllowedChannels,
}
