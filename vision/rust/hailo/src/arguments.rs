//! The command line: the networks to run on the Hailo-8, in the order requests name them.

pub const USAGE: &str = "usage: hailo (--detect <model.hef> <score_threshold> | \
                         --segment <model.hef> <cell_pixels>)...";

#[derive(Debug, PartialEq)]
pub enum Kind {
    /// The lowest score reported.
    Detection { score_threshold: f32 },
    /// The side of the cells a label stands for, in the model's input pixels.
    Segmentation { cell_pixels: usize },
}

#[derive(Debug, PartialEq)]
pub struct Network {
    pub hef_path: String,
    pub kind: Kind,
}

/// The networks `arguments` names, at least one, a request's index into them; `Err` says
/// what is wrong with them.
pub fn parse(arguments: &[String]) -> Result<Vec<Network>, String> {
    let mut networks = Vec::new();
    let mut arguments = arguments.iter();
    while let Some(flag) = arguments.next() {
        let (Some(hef_path), Some(value)) = (arguments.next(), arguments.next()) else {
            return Err(format!("{flag} takes a model and a value"));
        };
        let kind = match flag.as_str() {
            "--detect" => Kind::Detection {
                score_threshold: detection::score_threshold(value)?,
            },
            "--segment" => Kind::Segmentation {
                cell_pixels: value
                    .parse()
                    .ok()
                    .filter(|&pixels: &usize| pixels > 0)
                    .ok_or(format!("bad cell size {value}"))?,
            },
            other => return Err(format!("unknown argument {other}")),
        };
        networks.push(Network {
            hef_path: hef_path.clone(),
            kind,
        });
    }
    if networks.is_empty() {
        return Err("no network".to_string());
    }
    if networks.len() > usize::from(u8::MAX) + 1 {
        return Err(format!(
            "{} networks, more than a request can name",
            networks.len()
        ));
    }
    Ok(networks)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_line(line: &str) -> Result<Vec<Network>, String> {
        parse(
            &line
                .split_whitespace()
                .map(String::from)
                .collect::<Vec<_>>(),
        )
    }

    #[test]
    fn takes_any_networks_of_either_kind_in_order() {
        assert_eq!(
            parse_line("--segment road.hef 8 --detect a.hef 0.5 --detect b.hef 0.4"),
            Ok(vec![
                Network {
                    hef_path: "road.hef".into(),
                    kind: Kind::Segmentation { cell_pixels: 8 }
                },
                Network {
                    hef_path: "a.hef".into(),
                    kind: Kind::Detection {
                        score_threshold: 0.5
                    }
                },
                Network {
                    hef_path: "b.hef".into(),
                    kind: Kind::Detection {
                        score_threshold: 0.4
                    }
                },
            ])
        );
    }

    #[test]
    fn refuses_no_network_a_missing_value_a_bad_one_or_an_unknown_flag() {
        assert!(parse_line("").is_err());
        assert!(parse_line("--detect d.hef").is_err());
        assert!(parse_line("--detect d.hef 2").is_err());
        assert!(parse_line("--segment s.hef 0").is_err());
        assert!(parse_line("--classify c.hef 1").is_err());
    }
}
