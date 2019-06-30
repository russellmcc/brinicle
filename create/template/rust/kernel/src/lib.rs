#![warn(nonstandard_style, rust_2018_idioms, future_incompatible)]

use brinicle_kernel::Kernel as BrinicleKernel;
use brinicle_kernel::*;
use lazy_static::lazy_static;
use std::collections::BTreeMap;
mod config;
mod params;
mod state;

use brinicle_kernel::utils::EventOrAudio::*;

pub struct Kernel {
    format: AudioFormat,
    param_set: BTreeMap<u64, f64>,
    config: config::Config,
    state: state::State,
}

lazy_static! {
    static ref KERNEL_INFO: KernelInfo = KernelInfo {
        params: params::params(),
        kernel_type: kernel_type::KernelType::Effect,
        bypass_param: Some(params::Param::Bypass as u64),
        formats: vec![
            audio_format::AllowedFormat {
                input_channels: audio_format::AllowedChannels::ChannelCountAllowed(1),
                output_channels: audio_format::AllowedChannels::ChannelCountAllowed(1),
            },
            audio_format::AllowedFormat {
                input_channels: audio_format::AllowedChannels::ChannelCountAllowed(2),
                output_channels: audio_format::AllowedChannels::ChannelCountAllowed(2),
            },
        ],
    };
}

fn handle_event(kernel: &mut Kernel, data: event::Data) {
    match data {
        event::Data::ParameterChange { address, value } => kernel.set_parameter(address, value),
        event::Data::RampedParameterChange { address, value, .. } => {
            kernel.set_parameter(address, value)
        }
        event::Data::MIDIMessage { .. } => {}
    }
}

fn run_audio(kernel: &mut Kernel, mut audio: AudioBufferMut<'_, '_>) {
    if kernel.config.bypass {
        return;
    }
    for channel in &mut audio {
        for sample in channel {
            *sample *= kernel.config.gain
        }
    }
}

fn process<I>(kernel: &mut Kernel, audio: AudioBufferMut<'_, '_>, events: I)
where
    I: Iterator<Item = event::Event>,
{
    brinicle_kernel::utils::run_split_at_events(
        audio,
        events,
        |event_or_audio| match event_or_audio {
            Event(ev) => handle_event(kernel, ev.data),
            Audio(au) => run_audio(kernel, au),
        },
    )
}

impl BrinicleKernel for Kernel {
    fn info() -> &'static KernelInfo {
        &KERNEL_INFO
    }

    fn new(format: AudioFormat) -> Kernel {
        let param_set = params::params()
            .into_iter()
            .map(|info| {
                (
                    info.address,
                    match info.details {
                        parameter::Details::Numeric { default, .. } => default as f64,
                        parameter::Details::Indexed { default, .. } => default as f64,
                    },
                )
            })
            .collect();
        let config = config::from_params(format, &param_set);
        Kernel {
            format,
            param_set,
            config,
            state: state::State::default(),
        }
    }

    fn set_parameter(&mut self, address: u64, value: f64) {
        self.param_set.insert(address, value);
        self.config = config::from_params(self.format, &self.param_set);
    }

    fn get_parameter(&self, address: u64) -> f64 {
        self.param_set[&address]
    }

    fn process<I>(&mut self, audio: AudioBufferMut<'_, '_>, events: I)
    where
        I: Iterator<Item = event::Event>,
    {
        process(self, audio, events);
    }

    fn reset(&mut self) {
        self.state = state::State::default();
    }
}
