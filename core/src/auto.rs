//! Automatic edits derive from captured events; no global state or device access.
use crate::{model::*,project::{Project,Result,Error},commands::ChangeSet,time};
use serde_json::Value;
pub fn generate_zooms(p:&mut ProjectData, context:&Project, options:&Value, cs:&mut ChangeSet)->Result<()> {
    let scale=options.get("scale").and_then(Value::as_f64).unwrap_or(2.0);
    if !(1.0..=16.0).contains(&scale) {return Err(Error::new(1,"Invalid automatic zoom scale"));}
    p.zooms.retain(|z| z.mode!="auto");
    if !p.zoom_settings.automatic {cs.changed.push("zooms".into());return Ok(());}
    let points=context.session.source.content_rect_points;
    let mut candidates=Vec::new();
    for (i,_) in p.timeline.clips.iter().enumerate() {
        for (seg,events) in context.session.segments.iter().zip(&context.events) {
            let mut cursor=[points[2]/2.0,points[3]/2.0];
            for e in events {
                if let (Some(x),Some(y))=(e.x,e.y) {cursor=[x,y];}
                if e.kind!="down" && e.kind!="key" {continue;}
                if let Some(t)=time::source_to_timeline(&p.timeline.clips,i,seg.src_start_ns+e.t) { candidates.push((t,[(cursor[0]/points[2]).clamp(0.0,1.0),(cursor[1]/points[3]).clamp(0.0,1.0)])); }
            }
        }
    }
    candidates.sort_by_key(|c|c.0);
    let duration=time::duration(&p.timeline.clips);
    let mut clusters:Vec<(i64,i64,[f64;2],usize)>=Vec::new();
    for (t,target) in candidates {
        if let Some(last)=clusters.last_mut() {
            let dist=((last.2[0]-target[0]).powi(2)+(last.2[1]-target[1]).powi(2)).sqrt();
            if t-last.1<=1_200_000_000 && dist<0.30 { let count=last.3 as f64; last.2=[(last.2[0]*count+target[0])/(count+1.0),(last.2[1]*count+target[1])/(count+1.0)]; last.1=t;last.3+=1;continue; }
        }
        clusters.push((t,t,target,1));
    }
    let mut previous_end=0;
    for (i,(a,b,target,_)) in clusters.into_iter().enumerate() {
        let start=(a-300_000_000).max(previous_end).max(0); let end=(b+1_000_000_000).min(duration);
        if end<=start || p.zooms.iter().any(|z| z.mode=="manual" && z.tl_start_ns<end && z.tl_end_ns>start) {continue;}
        let id=format!("auto-{i}");
        p.zooms.push(Zoom{id:id.clone(),tl_start_ns:start,tl_end_ns:end,mode:"auto".into(),target,scale,ease_in_ns:300_000_000,ease_out_ns:300_000_000,enabled:true});
        cs.created_ids.push(id);previous_end=end;
    }
    p.zooms.sort_by_key(|z|z.tl_start_ns);cs.changed.push("zooms".into());Ok(())
}
pub fn speed_typing(p:&mut ProjectData, context:&Project, options:&Value, cs:&mut ChangeSet)->Result<()> {
    let speed=options.get("speed").and_then(Value::as_f64).unwrap_or(3.0);
    if !(1.0..=32.0).contains(&speed) {return Err(Error::new(1,"Invalid typing speed"));}
    let mut ranges=Vec::new();
    for (seg,events) in context.session.segments.iter().zip(&context.events) {
        let mut burst:Option<(i64,i64,usize)>=None;
        let mut finish=|b:Option<(i64,i64,usize)>| {if let Some((a,b,count))=b {if count>=3 {ranges.push(((seg.src_start_ns+a-150_000_000).max(seg.src_start_ns),(seg.src_start_ns+b+150_000_000).min(seg.src_start_ns+seg.duration_ns)));}}};
        for e in events.iter().filter(|e|e.kind=="key") {
            if let Some((_,last,_))=burst { if e.t-last>600_000_000 {finish(burst.take());} }
            if let Some(b)=&mut burst {b.1=e.t;b.2+=1;} else {burst=Some((e.t,e.t,1));}
        }
        finish(burst);
    }
    // Splits partition source ranges exactly; only one shared clip list changes.
    let mut next=Vec::new();
    for clip in &p.timeline.clips {
        let mut boundaries=vec![clip.src_start_ns,clip.src_end_ns];
        for (a,b) in &ranges {if *a>clip.src_start_ns && *a<clip.src_end_ns {boundaries.push(*a);} if *b>clip.src_start_ns && *b<clip.src_end_ns {boundaries.push(*b);} }
        boundaries.sort();boundaries.dedup();
        for (n,pair) in boundaries.windows(2).enumerate() {
            let mut c=clip.clone();c.src_start_ns=pair[0];c.src_end_ns=pair[1];
            if n>0 {c.id=crate::project::unique_id("clip");cs.created_ids.push(c.id.clone());}
            next.push(c);
        }
    }
    p.timeline.clips=next;
    let mut i=0;
    while i<p.timeline.clips.len() {
        let c=&p.timeline.clips[i];
        if ranges.iter().any(|(a,b)|c.src_start_ns>=*a && c.src_end_ns<=*b) {
            let start:f64=p.timeline.clips[..i].iter().map(time::clip_duration).sum();let old=time::clip_duration(c);
            p.timeline.clips[i].speed=speed;let new=time::clip_duration(&p.timeline.clips[i]);
            crate::commands::remap_effects(p,|t|{let t=t as f64;(if t<start {t} else if t<start+old {start+(t-start)*new/old} else {t+new-old}).round() as i64});
        }
        i+=1;
    }
    cs.changed.extend(["timeline".into(),"zooms".into(),"camera.layouts".into(),"cursor.ranges".into(),"audio.ranges".into()]);Ok(())
}
#[cfg(test)] mod tests {
    use super::*;use crate::{project::tests::Fixture,model::Event};use serde_json::json;
    #[test] fn clusters_typing_manual_preservation_and_global_off() {
        let f=Fixture::new();let mut p=Project::create(&f.0).unwrap();
        // Three separated clusters spanning both capture segments.
        p.events[0].retain(|e|e.kind!="down");p.events[1].retain(|e|e.kind!="down");
        for t in [300_000_000,400_000_000,1_800_000_000] {p.events[0].push(serde_json::from_value::<Event>(json!({"t":t,"type":"down","x":160,"y":100})).unwrap());}
        p.events[1].push(serde_json::from_value(json!({"t":700_000_000,"type":"key","key":"a"})).unwrap());
        for events in &mut p.events {events.sort_by_key(|e|e.t);}
        p.apply(&json!({"op":"auto_zooms"})).unwrap();assert_eq!(p.data.zooms.len(),3);
        let once=p.data.zooms.clone();p.apply(&json!({"op":"auto_zooms"})).unwrap();assert_eq!(p.data.zooms,once);
        p.apply(&json!({"op":"add_zoom","zoom":{"tl_start_ns":100_000_000,"tl_end_ns":1_000_000_000,"mode":"manual","target":[0.5,0.5],"scale":2,"ease_in_ns":0,"ease_out_ns":0}})).unwrap();
        p.apply(&json!({"op":"auto_zooms"})).unwrap();assert_eq!(p.data.zooms.iter().filter(|z|z.mode=="auto").count(),2);
        p.apply(&json!({"op":"set","path":"zoom_settings.automatic","value":false})).unwrap();p.apply(&json!({"op":"auto_zooms"})).unwrap();assert_eq!(p.data.zooms.len(),1);
    }
    #[test] fn typing_speed_and_silence_are_one_undo_step() {
        let f=Fixture::new();let mut p=Project::create(&f.0).unwrap();let original=p.data.clone();
        for t in [800_000_000,900_000_000,1_000_000_000] {p.events[0].push(serde_json::from_value(json!({"t":t,"type":"key","key":"a"})).unwrap());}
        p.events[0].sort_by_key(|e|e.t);
        p.apply(&json!({"op":"auto_speed_typing","speed":3})).unwrap();
        assert_eq!(p.data.timeline.clips.len(),3);assert_eq!(p.data.timeline.clips[1].speed,3.0);assert_eq!(time::duration(&p.data.timeline.clips),4_666_666_667);
        p.undo().unwrap();assert_eq!(p.data,original);
        p.apply(&json!({"op":"process_silence","mode":"cut","ranges":[{"tl_start_ns":0,"tl_end_ns":1_000_000_000},{"tl_start_ns":500_000_000,"tl_end_ns":2_000_000_000}]})).unwrap();assert_eq!(time::duration(&p.data.timeline.clips),3_000_000_000);
        p.undo().unwrap();assert_eq!(p.data,original);
        p.apply(&json!({"op":"process_silence","mode":"speed","speed":2,"ranges":[{"tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000}]})).unwrap();assert_eq!(time::duration(&p.data.timeline.clips),4_500_000_000);
        p.undo().unwrap();assert_eq!(p.data,original);
    }
}
