#[warn(nonstandard_style, rust_2018_idioms, future_incompatible)]
pub mod audio_format;
pub mod event;
pub mod kernel_type;
pub mod parameter;
pub mod utils;

pub use crate::audio_format::AudioFormat;
pub use brinicle_deinterleaved::AudioBuffer;
pub use brinicle_deinterleaved::AudioBufferMut;

pub struct KernelInfo {
    pub params: Vec<parameter::Info>,
    pub bypass_param: Option<u64>,
    pub kernel_type: kernel_type::KernelType,
    pub formats: Vec<audio_format::AllowedFormat>,
}

pub trait Kernel {
    fn info() -> &'static KernelInfo;
    fn new(format: audio_format::AudioFormat) -> Self;

    fn set_parameter(&mut self, address: u64, value: f64);
    fn get_parameter(&self, address: u64) -> f64;

    fn get_latency(&self) -> u64 {
        0
    }

    fn process<I>(&mut self, audio: AudioBufferMut, events: I)
    where
        I: Iterator<Item = event::Event>;

    fn reset(&mut self);
}
