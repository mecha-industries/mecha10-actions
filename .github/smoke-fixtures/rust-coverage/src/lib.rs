pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[cfg(feature = "extra")]
pub fn multiply(a: i32, b: i32) -> i32 {
    a * b
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_add() {
        assert_eq!(add(2, 3), 5);
    }

    #[cfg(feature = "extra")]
    #[test]
    fn test_multiply() {
        assert_eq!(multiply(2, 3), 6);
    }
}
