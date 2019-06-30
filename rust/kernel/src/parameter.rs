#[derive(Clone)]
pub enum Unit {
    Generic,
    Percent,
    Second,
    SampleFrames,
    Rate,
    Custom(String),
}

pub enum Details {
    Numeric {
        min: f64,
        max: f64,
        unit: Unit,
        default: f64,
    },
    Indexed {
        names: Vec<String>,
        default: usize,
    },
}

#[derive(Clone)]
pub enum DisplayScale {
    Linear,
    Logarithmic,
}

#[derive(Clone)]
pub struct Flags {
    pub writable: bool,
    pub readable: bool,
    pub scale: DisplayScale,
}

pub struct Info {
    pub id: String,
    pub address: u64,
    pub name: String,
    pub details: Details,
    pub flags: Flags,
    pub dependent_parameters: Vec<u64>,
}
