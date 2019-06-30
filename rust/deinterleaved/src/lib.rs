#![warn(nonstandard_style, rust_2018_idioms, future_incompatible)]
use std::ops::Index;
use std::ops::IndexMut;
use std::ops::Range;

use smallvec::SmallVec;

pub struct AudioBufferMut<'c, 'a: 'c> {
    buf: &'c mut [&'a mut [f32]],
}

fn all_same<I: Iterator>(iter: I) -> bool
where
    I::Item: PartialEq,
{
    let mut v = Option::None;
    for i in iter {
        v = match v {
            Option::None => Some(i),
            Option::Some(j) => {
                if i != j {
                    return false;
                }
                Some(j)
            }
        }
    }
    true
}

pub type SubBufferMut<'a> = SmallVec<[&'a mut [f32]; 8]>;

impl<'c, 'a: 'c> AudioBufferMut<'c, 'a> {
    pub fn new(buf: &'c mut [&'a mut [f32]]) -> AudioBufferMut<'c, 'a> {
        let mut ret = AudioBufferMut { buf };
        assert!(all_same((&mut ret).into_iter().map(|buf| buf.len())));
        ret
    }

    pub fn slice<'d>(&'d mut self, range: Range<usize>) -> SubBufferMut<'d> {
        let ret: SubBufferMut<'d> = self
            .buf
            .iter_mut()
            .map(|chan| (*chan).index_mut(range.clone()))
            .collect();
        ret
    }

    pub fn len(&self) -> usize {
        self.buf[0].len()
    }

    pub fn is_empty(&self) -> bool {
        self.buf[0].is_empty()
    }

    pub fn num_channels(&self) -> usize {
        self.buf.len()
    }

    pub fn split_first_mut<'d>(&'d mut self) -> Option<(&'d mut [f32], AudioBufferMut<'d, 'a>)> {
        match self.buf.split_first_mut() {
            None => None,
            Some((first, rest)) => Some((first, AudioBufferMut { buf: rest })),
        }
    }
}

impl<'c, 'a: 'c> From<&'c mut [&'a mut [f32]]> for AudioBufferMut<'c, 'a> {
    fn from(buf: &'c mut [&'a mut [f32]]) -> AudioBufferMut<'c, 'a> {
        AudioBufferMut::new(buf)
    }
}

impl<'c, 'a: 'c> From<&'c mut SubBufferMut<'a>> for AudioBufferMut<'c, 'a> {
    fn from(buf: &'c mut SubBufferMut<'a>) -> AudioBufferMut<'c, 'a> {
        AudioBufferMut::new(buf)
    }
}

impl<'d, 'c: 'd, 'a: 'c> From<&'d mut AudioBufferMut<'c, 'a>> for AudioBufferMut<'d, 'a> {
    fn from(buf: &'d mut AudioBufferMut<'c, 'a>) -> AudioBufferMut<'d, 'a> {
        AudioBufferMut::new(buf.buf)
    }
}

pub struct IterMut<'c, 'a: 'c> {
    iter: std::slice::IterMut<'c, &'a mut [f32]>,
}

impl<'c, 'a> Iterator for IterMut<'c, 'a> {
    type Item = &'c mut [f32];

    fn next(&mut self) -> Option<&'c mut [f32]> {
        self.iter.next().map(|r: &'c mut &'a mut [f32]| {
            let ret: &'c mut [f32] = *r;
            ret
        })
    }
}

impl<'d, 'c: 'd, 'a: 'c> IntoIterator for &'d mut AudioBufferMut<'c, 'a> {
    type Item = &'d mut [f32];
    type IntoIter = IterMut<'d, 'a>;
    fn into_iter(self) -> IterMut<'d, 'a> {
        IterMut {
            iter: self.buf.iter_mut(),
        }
    }
}

impl<'c, 'a: 'c> Index<usize> for AudioBufferMut<'c, 'a> {
    type Output = [f32];

    fn index(&self, index: usize) -> &[f32] {
        self.buf[index]
    }
}

impl<'c, 'a: 'c> IndexMut<usize> for AudioBufferMut<'c, 'a> {
    fn index_mut(&mut self, index: usize) -> &mut [f32] {
        self.buf[index]
    }
}

pub struct AudioBuffer<'c, 'a: 'c> {
    buf: &'c [&'a [f32]],
}

pub type SubBuffer<'a> = SmallVec<[&'a [f32]; 8]>;

impl<'c, 'a: 'c> AudioBuffer<'c, 'a> {
    pub fn new(buf: &'c [&'a [f32]]) -> AudioBuffer<'c, 'a> {
        let ret = AudioBuffer { buf };
        assert!(all_same((&ret).into_iter().map(|buf| buf.len())));
        ret
    }

    pub fn slice<'d>(&'d self, range: Range<usize>) -> SubBuffer<'d> {
        let ret: SubBuffer<'d> = self
            .buf
            .iter()
            .map(|chan| (*chan).index(range.clone()))
            .collect();
        ret
    }

    pub fn len(&self) -> usize {
        self.buf[0].len()
    }

    pub fn is_empty(&self) -> bool {
        self.buf[0].is_empty()
    }

    pub fn num_channels(&self) -> usize {
        self.buf.len()
    }

    pub fn split_first(&self) -> Option<(&'a [f32], AudioBuffer<'c, 'a>)> {
        match self.buf.split_first() {
            None => None,
            Some((first, rest)) => Some((first, AudioBuffer { buf: rest })),
        }
    }
}

impl<'c, 'a: 'c> From<&'c [&'a [f32]]> for AudioBuffer<'c, 'a> {
    fn from(buf: &'c [&'a [f32]]) -> AudioBuffer<'c, 'a> {
        AudioBuffer::new(buf)
    }
}

impl<'c, 'a: 'c> From<&'c SubBuffer<'a>> for AudioBuffer<'c, 'a> {
    fn from(buf: &'c SubBuffer<'a>) -> AudioBuffer<'c, 'a> {
        AudioBuffer::new(buf)
    }
}

impl<'d, 'c: 'd, 'a: 'c> From<&'d AudioBuffer<'c, 'a>> for AudioBuffer<'d, 'a> {
    fn from(buf: &'d AudioBuffer<'c, 'a>) -> AudioBuffer<'d, 'a> {
        AudioBuffer::new(buf.buf)
    }
}

impl<'c, 'a: 'c> From<AudioBufferMut<'c, 'a>> for AudioBuffer<'c, 'c> {
    fn from(buf: AudioBufferMut<'c, 'a>) -> AudioBuffer<'c, 'a> {
        unsafe { std::mem::transmute(buf) }
    }
}

pub struct Iter<'c, 'a: 'c> {
    iter: std::slice::Iter<'c, &'a [f32]>,
}

impl<'c, 'a> Iterator for Iter<'c, 'a> {
    type Item = &'c [f32];

    fn next(&mut self) -> Option<&'c [f32]> {
        self.iter.next().map(|r: &'c &'a [f32]| {
            let ret: &'c [f32] = *r;
            ret
        })
    }
}

impl<'d, 'c: 'd, 'a: 'c> IntoIterator for &'d AudioBuffer<'c, 'a> {
    type Item = &'d [f32];
    type IntoIter = Iter<'d, 'a>;
    fn into_iter(self) -> Iter<'d, 'a> {
        Iter {
            iter: self.buf.iter(),
        }
    }
}

impl<'c, 'a: 'c> Index<usize> for AudioBuffer<'c, 'a> {
    type Output = [f32];

    fn index(&self, index: usize) -> &[f32] {
        self.buf[index]
    }
}
