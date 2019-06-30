use super::params;
use brinicle_kernel::AudioFormat;
use std::collections::BTreeMap;

pub struct Config {
    pub gain: f32,
    pub bypass: bool,
}

pub fn from_params(_: AudioFormat, param_set: &BTreeMap<u64, f64>) -> Config {
    let gain = param_set[&(params::Param::Gain as u64)];
    #[allow(clippy::float_cmp)]
    let bypass = param_set[&(params::Param::Bypass as u64)] == 1.;
    Config {
        gain: gain as f32,
        bypass,
    }
}
