//! Analytic damped-spring response; independent of preview/export frame rate.
use crate::model::Spring;
pub fn preset(name: &str, custom: &Spring) -> Spring {
    let (tension, friction) = match name {
        "slow" => (90.0, 19.0),
        "mellow" => (180.0, 27.0),
        "quick" => (350.0, 37.5),
        "rapid" => (700.0, 53.0),
        _ => return custom.clone(),
    };
    Spring {
        tension,
        friction,
        mass: 1.0,
        allow_overshoot: false,
    }
}
/// Version zero preserves the original Yapcam preset response on saved projects.
pub fn cursor_preset(name: &str, custom: &Spring, version: u32) -> Spring {
    if version == 0 {
        return preset(name, custom);
    }
    let (tension, friction, mass) = match name {
        "smooth" => (470.0, 70.0, 3.0),
        "medium" => (340.0, 60.0, 3.0),
        "rapid" => (530.0, 40.0, 1.0),
        _ => return preset(name, custom),
    };
    Spring {
        tension,
        friction,
        mass,
        allow_overshoot: false,
    }
}
/// Conservative envelope bound at precision .002, without a per-frame search.
/// Critical damping uses (1+u)e^-u <= 2e^(-u/2).
fn settle_seconds(s: &Spring) -> f64 {
    let w = (s.tension / s.mass).sqrt();
    let z = s.friction / (2.0 * (s.tension * s.mass).sqrt());
    if (z - 1.0).abs() < 1e-5 {
        2.0 * (2.0_f64 / 0.002).ln() / w
    } else if z < 1.0 {
        (1.0 / (0.002 * (1.0 - z * z).sqrt())).ln() / (z * w)
    } else {
        let root = (z * z - 1.0).sqrt();
        // Stable slow pole even at high damping.
        let a = w / (z + root);
        let b = w * (z + root);
        (b / ((b - a) * 0.002)).ln() / a
    }
}
/// Compress time by scaling stiffness by r² and damping by r. Short ramps snap.
pub fn aligned_transition(t: f64, duration: f64, fps: f64, spring: &Spring) -> f64 {
    if t <= 0.0 {
        return 0.0;
    }
    if t >= 1.0 || duration < 2.0 / fps.max(1.0) {
        return 1.0;
    }
    let mut s = spring.clone();
    let ratio = (settle_seconds(&s) / duration).max(1.0);
    s.tension *= ratio * ratio;
    s.friction *= ratio;
    s.allow_overshoot = false;
    let end = response(duration, &s).max(0.00001);
    (response(t * duration, &s) / end).clamp(0.0, 1.0)
}
pub fn response(seconds: f64, s: &Spring) -> f64 {
    if seconds <= 0.0 {
        return 0.0;
    }
    let w = (s.tension / s.mass).sqrt();
    let z = s.friction / (2.0 * (s.tension * s.mass).sqrt());
    let y = if (z - 1.0).abs() < 1e-5 {
        1.0 - (1.0 + w * seconds) * (-w * seconds).exp()
    } else if z < 1.0 {
        let d = w * (1.0 - z * z).sqrt();
        1.0 - (-z * w * seconds).exp()
            * ((d * seconds).cos() + z / (1.0 - z * z).sqrt() * (d * seconds).sin())
    } else {
        let root = (z * z - 1.0).sqrt();
        let a = -w * (z - root);
        let b = -w * (z + root);
        1.0 - (b * (a * seconds).exp() - a * (b * seconds).exp()) / (b - a)
    };
    if s.allow_overshoot {
        y
    } else {
        y.clamp(0.0, 1.0)
    }
}
pub fn transition(t: f64, duration_seconds: f64, s: &Spring) -> f64 {
    if t >= 1.0 {
        return 1.0;
    }
    if t <= 0.0 {
        return 0.0;
    }
    let t = t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
    let end = response(duration_seconds, s).max(0.00001);
    let value = response(t * duration_seconds, s) / end;
    if s.allow_overshoot {
        value
    } else {
        value.clamp(0.0, 1.0)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn versioned_presets_compress_and_snap_without_changing_legacy_curves() {
        let custom = Spring::default();
        for (name, triple) in [
            ("smooth", (470.0, 70.0, 3.0)),
            ("medium", (340.0, 60.0, 3.0)),
            ("rapid", (530.0, 40.0, 1.0)),
        ] {
            let p = cursor_preset(name, &custom, 1);
            assert_eq!((p.tension, p.friction, p.mass), triple);
        }
        assert_eq!(cursor_preset("rapid", &custom, 0).tension, 700.0);
        let slow = Spring {
            tension: 5.0,
            friction: 5.0,
            mass: 15.0,
            allow_overshoot: false,
        };
        assert!(response(0.3, &slow) < 0.1);
        assert!(aligned_transition(0.99, 0.3, 60.0, &slow) > 0.997);
        assert_eq!(aligned_transition(0.1, 0.03, 60.0, &slow), 1.0);
        assert!(aligned_transition(0.001, 2.0 / 60.0, 60.0, &slow) < 1.0);
        for tension in [5.0, 125.0, 600.0] {
            for friction in [5.0, 40.0, 200.0] {
                for mass in [0.1, 1.5, 15.0] {
                    let s = Spring {
                        tension,
                        friction,
                        mass,
                        allow_overshoot: false,
                    };
                    for duration in [0.034, 0.35, 3.0] {
                        assert!((1.0 - response(settle_seconds(&s), &s)).abs() <= 0.00201);
                        for t in [0.0, 0.01, 0.5, 0.99, 1.0] {
                            let r = aligned_transition(t, duration, 60.0, &s);
                            assert!(r.is_finite() && (0.0..=1.0).contains(&r));
                        }
                    }
                }
            }
        }
    }
    #[test]
    fn stable_presets_and_physics() {
        for name in ["slow", "mellow", "quick", "rapid"] {
            let p = preset(name, &Spring::default());
            let mut last = 0.0;
            for n in 0..500 {
                let r = response(n as f64 / 100.0, &p);
                assert!(r >= last - 1e-7 && r <= 1.0);
                last = r;
            }
            assert!(last > 0.999);
        }
        let under = Spring {
            tension: 250.0,
            friction: 3.0,
            mass: 1.0,
            allow_overshoot: true,
        };
        assert!((1..100).any(|n| response(n as f64 / 100.0, &under) > 1.0));
        let over = Spring {
            friction: 80.0,
            ..Spring::default()
        };
        assert!(response(10.0, &over) > 0.999);
    }
}
