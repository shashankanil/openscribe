//! Run the same native OCR path as screenshot capture on an explicit local PNG.
fn main() -> Result<(), String> {
    let path = std::env::args_os().nth(1).ok_or("Pass a PNG path.")?;
    let text = openscribe_desktop_lib::ocr::recognize_path(std::path::Path::new(&path))?
        .ok_or("Windows OCR returned no text.")?;
    println!("{text}");
    Ok(())
}
