pub fn value() -> usize {
    let _a = tokio::fs::remove_file("testing");
    1333
}

#[cfg(test)]
mod tests {
    #[test]
    fn fail() {
    }
}
