import Foundation

/// The body-text specimens of the Text tab: original prose written for Fontory (a title line, then paragraphs).
/// Paragraphs are separated by single newlines; the renderer spaces them.
public enum BodyTextSamples {
    public static let english = PreviewSamples.Sample(name: "English", text: """
        On Reading Small Letters
        Every page begins as a field of quiet gray. Step back from a well-set paragraph and the words dissolve into \
        texture — an even weave of strokes and spaces that the eye crosses without stumbling. That evenness is no \
        accident; it is the sum of thousands of small decisions about weight, width and the room between letters.
        A reader rarely notices any of this. She notices the story, the argument, the recipe for bread that calls for \
        500 grams of flour and 2 teaspoons of salt. The type has done its job when it disappears, the way a good window \
        shows the garden rather than the glass.
        Still, look closely and the letters have personalities. A lowercase “g” may carry a second bowl like a pair of \
        spectacles, or swing a single open tail. The “a” might keep a tidy roof over its belly, while the “e” tilts its \
        bar as if caught mid-sentence. Capitals tend to be formal; Q, R and K reveal the most about a designer’s temper.
        Numbers need their own care. Figures that stack in columns, 1,234.56 above 7,890.12, help the accountant; \
        figures that rise and fall with the lowercase sit more gracefully in a sentence about the year 1897 or a room \
        with 12 windows. Punctuation must hold its place too: commas, colons; question marks? exclamation points!
        Spacing is the hidden half of the craft. Set the lines too close and the descenders of one row tangle with the \
        ascenders of the next; set them too far apart and each line drifts off like a raft. Somewhere between 1.3 and \
        1.5 times the size of the type, most text settles into an easy rhythm.
        So read this paragraph slowly, then quickly, then from across the room. Change the size, the columns, the \
        color of the page. When the words still feel effortless at every distance, you have found a typeface worth \
        keeping.
        """)

    public static let vietnamese = PreviewSamples.Sample(name: "Tiếng Việt", text: """
        Đọc những con chữ nhỏ
        Mỗi trang sách đều bắt đầu bằng một mảng xám lặng lẽ. Lùi lại một bước, những dòng chữ được sắp đặt khéo léo \
        hòa thành một tấm vải đều đặn — nét và khoảng trắng đan vào nhau, để mắt người đọc lướt qua mà không vấp.
        Người đọc hiếm khi để ý điều đó. Họ chỉ thấy câu chuyện, lập luận, hay công thức làm bánh cần 500 gam bột và \
        2 thìa muối. Kiểu chữ đã làm tròn bổn phận khi nó biến mất, như một ô cửa sổ tốt cho ta thấy khu vườn chứ \
        không phải tấm kính.
        Tiếng Việt đòi hỏi nhiều hơn thế. Chữ “ữ” mang cả móc lẫn dấu ngã; chữ “ệ” vừa có dấu mũ vừa có dấu nặng. Các dấu \
        phải đủ rõ để phân biệt “ma, má, mà, mả, mã, mạ”, nhưng cũng đủ nhẹ để dòng chữ không trở nên rối mắt.
        Con số cũng cần được chăm chút. Những chữ số thẳng hàng như 1.234,56 giúp người kế toán; những chữ số lên \
        xuống theo chữ thường lại hợp hơn khi nằm giữa câu văn về năm 1945 hay một căn phòng có 12 ô cửa. Dấu câu \
        phải giữ đúng chỗ: dấu phẩy, dấu hai chấm; dấu hỏi? và dấu chấm than!
        Khoảng cách là nửa thầm lặng của nghề. Đặt các dòng quá sát, phần đuôi của dòng trên vướng vào phần đầu của \
        dòng dưới; đặt quá xa, mỗi dòng trôi đi như một chiếc bè. Ở khoảng 1,3 đến 1,5 lần cỡ chữ, phần lớn văn bản \
        tìm được nhịp điệu dễ chịu.
        Hãy đọc đoạn này thật chậm, rồi thật nhanh, rồi từ cuối căn phòng. Đổi cỡ chữ, số cột, màu giấy. Khi chữ vẫn \
        dễ đọc ở mọi khoảng cách, bạn đã tìm được một kiểu chữ đáng giữ lại.
        """)

    public static let all: [PreviewSamples.Sample] = [english, vietnamese]
}
