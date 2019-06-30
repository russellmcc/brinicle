use brinicle_kernel::parameter::*;

pub enum Param {
    Bypass,
    Gain,
}

pub fn params() -> Vec<Info> {
    let flags = Flags {
        writable: true,
        readable: true,
        scale: DisplayScale::Logarithmic,
    };

    vec![
        Info {
            id: "bypass".to_string(),
            address: Param::Bypass as u64,
            name: "Bypass".to_string(),
            details: Details::Numeric {
                min: 0.,
                max: 1.,
                unit: Unit::Generic,
                default: 0.,
            },
            flags: Flags {
                writable: true,
                readable: true,
                scale: DisplayScale::Linear,
            },
            dependent_parameters: vec![],
        },
        Info {
            id: "gain".to_string(),
            address: Param::Gain as u64,
            name: "Gain".to_string(),
            details: Details::Numeric {
                min: 0.,
                max: 1.,
                unit: Unit::Generic,
                default: 0.1,
            },
            flags: flags.clone(),
            dependent_parameters: vec![],
        },
    ]
}
