const NAL_SPS = 7
const KEY_FRAME_FLAG = 1
const HEADER_BYTES = 13

/**
 * A frame the `video:<camera>` channel pushes: a flags byte, bit 0 a key frame, the capture time in microseconds,
 * little-endian 64-bit, the width and the height, little-endian 16-bit, then the frame's NAL units in Annex B form.
 */
export function readVideoFrame(payload) {
  const view = new DataView(payload)
  return {
    key: (view.getUint8(0) & KEY_FRAME_FLAG) !== 0,
    captureUs: Number(view.getBigInt64(1, true)),
    width: view.getUint16(9, true),
    height: view.getUint16(11, true),
    data: new Uint8Array(payload, HEADER_BYTES)
  }
}

/** The NAL units of an Annex B frame, without their start codes. */
export function nalUnits(data) {
  const starts = []
  for (let index = 0; index + 2 < data.length; index++) {
    if (data[index] === 0 && data[index + 1] === 0 && data[index + 2] === 1) {
      starts.push(index + 3)
      index += 2
    }
  }
  return starts.map((start, index) => {
    let end = index + 1 < starts.length ? starts[index + 1] - 3 : data.length
    // A 4-byte start code's leading zero belongs to no unit.
    if (index + 1 < starts.length && data[end - 1] === 0) end -= 1
    return data.subarray(start, end)
  })
}

const hex = (byte) => byte.toString(16).padStart(2, '0')

/**
 * The `avc1.PPCCLL` codec string of an Annex B frame, from its sequence parameter set: the profile, constraint flags
 * and level; `null` for a frame without one, which only a key frame carries.
 */
export function codecOf(data) {
  const sps = nalUnits(data).find((unit) => (unit[0] & 0x1f) === NAL_SPS)
  return sps ? `avc1.${[...sps.subarray(1, 4)].map(hex).join('')}` : null
}
