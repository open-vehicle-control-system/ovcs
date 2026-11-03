//! Pairs left and right frames whose start times are close enough to match.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    Left,
    Right,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Pair {
    pub left_ns: i64,
    pub right_ns: i64,
    pub left: Vec<u8>,
    pub right: Vec<u8>,
}

/// Holds the newest unpaired frame of each side.
pub struct Pairer {
    tolerance_ns: i64,
    left: Option<(i64, Vec<u8>)>,
    right: Option<(i64, Vec<u8>)>,
}

impl Pairer {
    pub fn new(tolerance_ns: i64) -> Pairer {
        Pairer {
            tolerance_ns,
            left: None,
            right: None,
        }
    }

    /// Stores `frame` as its side's newest frame and returns the pair it
    /// completes, if the other side's newest frame started within the tolerance.
    pub fn push(&mut self, side: Side, start_ns: i64, frame: Vec<u8>) -> Option<Pair> {
        match side {
            Side::Left => self.left = Some((start_ns, frame)),
            Side::Right => self.right = Some((start_ns, frame)),
        }
        let (left_ns, right_ns) = match (&self.left, &self.right) {
            (Some((left_ns, _)), Some((right_ns, _)))
                if (left_ns - right_ns).abs() <= self.tolerance_ns =>
            {
                (*left_ns, *right_ns)
            }
            _ => return None,
        };
        Some(Pair {
            left_ns,
            right_ns,
            left: self.left.take().map(|(_, frame)| frame).unwrap_or_default(),
            right: self
                .right
                .take()
                .map(|(_, frame)| frame)
                .unwrap_or_default(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairs_frames_within_the_tolerance() {
        let mut pairer = Pairer::new(1_000_000);
        assert!(pairer.push(Side::Left, 0, vec![1]).is_none());
        let pair = pairer.push(Side::Right, 400_000, vec![2]).unwrap();
        assert_eq!(
            (pair.left_ns, pair.right_ns, pair.left, pair.right),
            (0, 400_000, vec![1], vec![2])
        );
    }

    #[test]
    fn keeps_only_the_newest_frame_per_side() {
        let mut pairer = Pairer::new(1_000_000);
        assert!(pairer.push(Side::Left, 10_000_000, vec![3]).is_none());
        assert!(pairer.push(Side::Right, 12_000_000, vec![4]).is_none());
        let pair = pairer.push(Side::Left, 12_500_000, vec![5]).unwrap();
        assert_eq!((pair.left, pair.right), (vec![5], vec![4]));
    }

    #[test]
    fn a_paired_frame_is_not_paired_again() {
        let mut pairer = Pairer::new(1_000_000);
        pairer.push(Side::Left, 0, vec![1]);
        assert!(pairer.push(Side::Right, 0, vec![2]).is_some());
        assert!(pairer.push(Side::Right, 100, vec![3]).is_none());
    }
}
