//! Analytic damped-spring response; independent of preview/export frame rate.
use crate::model::Spring;
pub fn preset(name: &str, custom: &Spring) -> Spring {
    let (tension,friction) = match name { "slow"=>(90.0,19.0),"mellow"=>(180.0,27.0),"quick"=>(350.0,37.5),"rapid"=>(700.0,53.0),_=>return custom.clone() };
    Spring { tension,friction,mass:1.0,allow_overshoot:false }
}
pub fn response(seconds:f64,s:&Spring)->f64 {
    if seconds<=0.0 {return 0.0;}
    let w=(s.tension/s.mass).sqrt(); let z=s.friction/(2.0*(s.tension*s.mass).sqrt());
    let y=if (z-1.0).abs()<1e-5 {1.0-(1.0+w*seconds)*(-w*seconds).exp()}
    else if z<1.0 {let d=w*(1.0-z*z).sqrt(); 1.0-(-z*w*seconds).exp()*((d*seconds).cos()+z/(1.0-z*z).sqrt()*(d*seconds).sin())}
    else { let root=(z*z-1.0).sqrt(); let a=-w*(z-root); let b=-w*(z+root); 1.0-(b*(a*seconds).exp()-a*(b*seconds).exp())/(b-a) };
    if s.allow_overshoot {y} else {y.clamp(0.0,1.0)}
}
pub fn transition(t:f64,duration_seconds:f64,s:&Spring)->f64 {
    if t>=1.0 {return 1.0;} if t<=0.0 {return 0.0;}
    let end=response(duration_seconds,s).max(0.00001);
    let value=response(t*duration_seconds,s)/end;
    if s.allow_overshoot {value} else {value.clamp(0.0,1.0)}
}
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn stable_presets_and_physics() {
        for name in ["slow","mellow","quick","rapid"] {let p=preset(name,&Spring::default()); let mut last=0.0; for n in 0..500 {let r=response(n as f64/100.0,&p); assert!(r>=last-1e-7 && r<=1.0); last=r;} assert!(last>0.999);}
        let under=Spring{tension:250.0,friction:3.0,mass:1.0,allow_overshoot:true}; assert!((1..100).any(|n| response(n as f64/100.0,&under)>1.0));
        let over=Spring{friction:80.0,..Spring::default()}; assert!(response(10.0,&over)>0.999);
    }
}
