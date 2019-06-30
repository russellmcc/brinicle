use brinicle_kernel::event;
use brinicle_kernel::parameter::*;
use brinicle_kernel::Kernel;
use libc::c_char;
use libc::c_void;
use smallvec::SmallVec;
use std::ffi::CString;

fn convert_unit(unit: &Unit) -> u64 {
    match unit {
        Unit::Generic => 0,
        Unit::Percent => 3,
        Unit::Second => 4,
        Unit::SampleFrames => 5,
        Unit::Rate => 7,
        Unit::Custom(..) => 26,
    }
}

fn convert_flags(readable: bool, writable: bool, scale: &DisplayScale) -> u64 {
    (if readable { 1 << 30 } else { 0 })
        | (if writable { 1 << 31 } else { 0 })
        | (match scale {
            DisplayScale::Linear => 0,
            DisplayScale::Logarithmic => 1 << 22,
        })
}

fn vec_as_ptr<T>(v: &[T]) -> *const T {
    if !v.is_empty() {
        &v[0] as *const T
    } else {
        std::ptr::null()
    }
}

pub fn get_kernel_allowed_channel_formats<K: Kernel>(
    add_format_ctx: *mut c_void,
    add_format: extern "C" fn(ctx: *mut c_void, input: i32, output: i32),
) {
    let formats = &K::info().formats;
    let serialize = |channels| -> i32 {
        match channels {
            brinicle_kernel::audio_format::AllowedChannels::AnyChannelCountAllowed => -1,
            brinicle_kernel::audio_format::AllowedChannels::ChannelCountAllowed(x) => x as i32,
        }
    };
    for format in formats {
        add_format(
            add_format_ctx,
            serialize(format.input_channels),
            serialize(format.output_channels),
        );
    }
}

pub fn get_has_bypass_param<K: Kernel>() -> u64 {
    match K::info().bypass_param {
        None => 0,
        Some(..) => 1,
    }
}

pub fn get_bypass_param<K: Kernel>() -> u64 {
    match K::info().bypass_param {
        None => 0,
        Some(n) => n,
    }
}

pub fn get_params<K: Kernel>(
    num_ctx: *mut c_void,
    numeric_param: extern "C" fn(
        ctx: *mut c_void,
        id: *const c_char,
        address: u64,
        name: *const c_char,
        flags: u64,
        min: f64,
        max: f64,
        unit_num: u64,
        unit_custom_name: *const c_char,
        default: f64,
        first_dep_param: *const u64,
        num_dep_params: u64,
    ),
    indexed_ctx: *mut c_void,
    indexed_param: extern "C" fn(
        ctx: *mut c_void,
        id: *const c_char,
        address: u64,
        name: *const c_char,
        flags: u64,
        value_strings: *const (*const c_char),
        num_value_strings: u64,
        default: u64,
        first_dep_param: *const u64,
        num_dep_params: u64,
    ),
) {
    let params = &K::info().params;
    for param in params {
        let c_id = CString::new(param.id.clone()).unwrap();
        let c_name = CString::new(param.name.clone()).unwrap();
        let flags = convert_flags(
            param.flags.writable,
            param.flags.readable,
            &param.flags.scale,
        );
        match &param.details {
            Details::Numeric {
                min,
                max,
                unit,
                default,
            } => {
                numeric_param(
                    num_ctx,
                    c_id.as_ptr(),
                    param.address,
                    c_name.as_ptr(),
                    flags,
                    *min,
                    *max,
                    convert_unit(unit),
                    if let Unit::Custom(ref unit_custom) = unit {
                        let c_unit_name = CString::new(unit_custom.clone()).unwrap();
                        c_unit_name.as_ptr()
                    } else {
                        std::ptr::null()
                    },
                    *default,
                    vec_as_ptr(&param.dependent_parameters),
                    param.dependent_parameters.len() as u64,
                );
            }
            Details::Indexed { names, default } => {
                let c_names: Vec<_> = names
                    .iter()
                    .map(|name| CString::new(name.clone()).unwrap())
                    .collect();
                let c_ptr_names: Vec<*const c_char> =
                    c_names.iter().map(|c_name| c_name.as_ptr()).collect();

                indexed_param(
                    indexed_ctx,
                    c_id.as_ptr(),
                    param.address,
                    c_name.as_ptr(),
                    flags,
                    vec_as_ptr(&c_ptr_names),
                    c_ptr_names.len() as u64,
                    *default as u64,
                    vec_as_ptr(&param.dependent_parameters),
                    param.dependent_parameters.len() as u64,
                );
            }
        }
    }
}

pub fn get_kernel_type<K: Kernel>() -> u32 {
    K::info().kernel_type as u32
}

pub fn create_kernel<K: Kernel>(input_count: u32, output_count: u32, sample_rate: f64) -> *mut K {
    Box::into_raw(Box::new(K::new(brinicle_kernel::AudioFormat {
        input_channel_count: input_count,
        output_channel_count: output_count,
        sample_rate,
    })))
}

pub unsafe fn delete_kernel<K: Kernel>(k: *mut K) {
    Box::from_raw(k);
}

pub unsafe fn set_kernel_parameter<K: Kernel>(k: *mut K, address: u64, value: f64) {
    let k2: &mut K = &mut *k;
    k2.set_parameter(address, value)
}

pub unsafe fn get_kernel_parameter<K: Kernel>(k: *const K, address: u64) -> f64 {
    let k2: &K = &*k;
    k2.get_parameter(address)
}

pub unsafe fn get_kernel_latency<K: Kernel>(k: *const K) -> u64 {
    let k2: &K = &*k;
    k2.get_latency()
}

pub unsafe fn reset_kernel<K: Kernel>(k: *mut K) {
    let k2: &mut K = &mut *k;
    k2.reset();
}

#[repr(C)]
pub struct GlueEvent {
    pub time: i64,
    pub ty: u64,

    pub param_addr: u64,
    pub param_value: f64,
    pub param_ramp_time: u32,

    pub midi_cable: u8,
    pub midi_valid_bytes: u16,
    pub midi_bytes: [u8; 3],
}

struct GlueEventStream {
    events_ctx: *mut c_void,
    events_fn: extern "C" fn(ctx: *mut c_void) -> *const GlueEvent,
}

impl Iterator for GlueEventStream {
    type Item = event::Event;
    fn next(&mut self) -> Option<Self::Item> {
        let gp = (self.events_fn)(self.events_ctx);
        if gp.is_null() {
            return None;
        }
        let ge = unsafe { &*gp };
        Some(event::Event {
            time: ge.time,
            data: match ge.ty {
                0 => event::Data::ParameterChange {
                    address: ge.param_addr,
                    value: ge.param_value,
                },
                1 => event::Data::RampedParameterChange {
                    address: ge.param_addr,
                    value: ge.param_value,
                    ramp_time: ge.param_ramp_time,
                },
                2 => event::Data::MIDIMessage {
                    cable: ge.midi_cable,
                    valid_bytes: ge.midi_valid_bytes,
                    bytes: ge.midi_bytes,
                },
                _ => event::Data::ParameterChange {
                    address: ge.param_addr,
                    value: ge.param_value,
                },
            },
        })
    }
}

pub unsafe fn process_kernel<K: Kernel>(
    k: *mut K,
    data: *mut *mut f32,
    chans: u64,
    samples: u64,
    events_ctx: *mut c_void,
    events_fn: extern "C" fn(ctx: *mut c_void) -> *const GlueEvent,
) {
    let glue_events = GlueEventStream {
        events_ctx,
        events_fn,
    };
    let mut chan_vec: SmallVec<[&mut [f32]; 8]> = (0..chans)
        .map(|chan| {
            let slice_ptr = *data.offset(chan as isize);
            std::slice::from_raw_parts_mut(slice_ptr, samples as usize)
        })
        .collect();
    let k2: &mut K = &mut *k;
    k2.process((&mut chan_vec).into(), glue_events);
}

#[macro_export]
macro_rules! generate_glue {
    ($K:ty) => {
        use libc::c_char;
        use libc::c_void;

        #[no_mangle]
        pub extern "C" fn get_kernel_allowed_channel_formats(
            add_format_ctx: *mut c_void,
            add_format: extern "C" fn(ctx: *mut c_void, input: i32, output: i32),
        ) {
            $crate::detail::get_kernel_allowed_channel_formats::<$K>(add_format_ctx, add_format);
        }

        #[no_mangle]
        pub extern "C" fn get_has_bypass_param() -> u64 {
            $crate::detail::get_has_bypass_param::<$K>()
        }

        #[no_mangle]
        pub extern "C" fn get_bypass_param() -> u64 {
            $crate::detail::get_bypass_param::<$K>()
        }

        #[no_mangle]
        extern "C" fn get_params(
            num_ctx: *mut c_void,
            numeric_param: extern "C" fn(
                ctx: *mut c_void,
                id: *const c_char,
                address: u64,
                name: *const c_char,
                flags: u64,
                min: f64,
                max: f64,
                unit_num: u64,
                unit_custom_name: *const c_char,
                default: f64,
                first_dep_param: *const u64,
                num_dep_params: u64,
            ),
            indexed_ctx: *mut c_void,
            indexed_param: extern "C" fn(
                ctx: *mut c_void,
                id: *const c_char,
                address: u64,
                name: *const c_char,
                flags: u64,
                value_strings: *const (*const c_char),
                num_value_strings: u64,
                default: u64,
                first_dep_param: *const u64,
                num_dep_params: u64,
            ),
        ) {
            $crate::detail::get_params::<$K>(num_ctx, numeric_param, indexed_ctx, indexed_param);
        }

        #[no_mangle]
        unsafe extern "C" fn get_kernel_type() -> u32 {
            $crate::detail::get_kernel_type::<$K>()
        }

        #[no_mangle]
        extern "C" fn create_kernel(
            input_count: u32,
            output_count: u32,
            sample_rate: f64,
        ) -> *mut $K {
            $crate::detail::create_kernel(input_count, output_count, sample_rate)
        }

        #[no_mangle]
        unsafe extern "C" fn delete_kernel(k: *mut $K) {
            $crate::detail::delete_kernel(k)
        }

        #[no_mangle]
        unsafe extern "C" fn set_kernel_parameter(k: *mut $K, address: u64, value: f64) {
            $crate::detail::set_kernel_parameter(k, address, value)
        }

        #[no_mangle]
        unsafe extern "C" fn get_kernel_parameter(k: *const $K, address: u64) -> f64 {
            $crate::detail::get_kernel_parameter(k, address)
        }

        #[no_mangle]
        unsafe extern "C" fn get_kernel_latency(k: *const $K) -> u64 {
            $crate::detail::get_kernel_latency(k)
        }

        #[no_mangle]
        unsafe extern "C" fn reset_kernel(k: *mut $K) {
            $crate::detail::reset_kernel(k)
        }

        #[no_mangle]
        unsafe extern "C" fn process_kernel(
            k: *mut $K,
            data: *mut *mut f32,
            chans: u64,
            samples: u64,
            events_ctx: *mut c_void,
            events_fn: extern "C" fn(ctx: *mut c_void) -> *const brinicle_glue::detail::GlueEvent,
        ) {
            $crate::detail::process_kernel(k, data, chans, samples, events_ctx, events_fn)
        }
    };
}
