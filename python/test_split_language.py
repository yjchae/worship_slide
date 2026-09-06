"""보조 언어 줄 판별 self-check (LibreOffice 불필요)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from ppt_tool import is_sub_line, split_bilingual_page


def test_is_sub_line():
    # 한글이 있으면 무조건 본문
    assert not is_sub_line("주님의 은혜")
    assert not is_sub_line("오 주님 Amazing")
    # 숫자·기호만 있는 줄은 예전처럼 본문 쪽
    assert not is_sub_line("1. 2. 3.")
    assert not is_sub_line("- * -")
    # 라틴 문자
    assert is_sub_line("Amazing Grace")
    # 라틴이 아닌 언어도 보조로 (예전 60% 규칙이 놓치던 부분)
    assert is_sub_line("主の恵み")
    assert is_sub_line("你的恩典")
    assert is_sub_line("Ваша благодать")


def test_split():
    korean, sub = split_bilingual_page("주의 은혜\n主の恵み\n\n두 번째 줄\nAmazing")
    assert korean == "주의 은혜\n두 번째 줄", korean
    assert sub == "主の恵み\nAmazing", sub


if __name__ == "__main__":
    test_is_sub_line()
    test_split()
    print("OK")
