import KioskKeyboard from "kioskboard";

KioskKeyboard.init({
  keysArrayOfObjects: [
    {
      "0": "A",
      "1": "Z",
      "2": "E",
      "3": "R",
      "4": "T",
      "5": "Y",
      "6": "U",
      "7": "I",
      "8": "O",
      "9": "P"
    },
    {
      "0": "Q",
      "1": "S",
      "2": "D",
      "3": "F",
      "4": "G",
      "5": "H",
      "6": "J",
      "7": "K",
      "8": "L",
      "9": "M"
    },
    {
      "0": "W",
      "1": "X",
      "2": "C",
      "3": "V",
      "4": "B",
      "5": "N"
    }
  ],
  theme: "dark"
});

export default KioskKeyboard;