<template>
    <div class="container">
        <div class="center">
        <div class="speedometr">
        <svg class="speed"
        width="400"
        height="342"
        viewBox="0 0 400 342">
        <defs>
            <linearGradient id="linear" x1="0%" y1="0%" x2="100%" y2="0%">
            <stop offset="0%"   stop-color="#0c9c00"/>

            <stop offset="100%" stop-color="#ff0000"/>
            </linearGradient>
        </defs>
        <defs>
            <linearGradient id="linear2" x1="0%" y1="0%" x2="100%" y2="0%">
            <stop offset="50%"   stop-color="#fff"/>

            <stop offset="90%" stop-color="rgba(255,255,255,0)"/>
            </linearGradient>
        </defs>
        <defs>
            <filter id="f4" x="0" y="0" width="200%" height="200%">
            <feOffset result="offOut" in="SourceGraphic" dx="0" dy="0" />

            <feGaussianBlur result="blurOut" in="matrixOut" stdDeviation="25" />
            <feBlend in="SourceGraphic" in2="blurOut" mode="normal" />
            </filter>
        </defs>
        <defs>
            <filter id="f1" x="0" y="0">
            <feGaussianBlur in="SourceGraphic" stdDeviation="7" />
            </filter>
        </defs>

        <path  id="arc2"
            style="fill:none;fill-rule:evenodd;stroke-width:52;stroke-miterlimit:1;stroke-opacity:0.05;transform-origin:180px 180px;transform:scale(0.9 0.9)"
            transform="scale(0.9 0.9) translate(20 18)"
            stroke="url(#linear)"
            filter="url(#f1)"

                d="m 66.906305,293.33748 a 160.10918,160.10918 0 0 1 10e-7,-226.428566 a 160.10918,160.10918 0 0 1 226.428574,10e-7 a 160.10918,160.10918 0 0 1 -10e-6,226.428565" />
        <path id="path"
            style="fill:none;fill-rule:evenodd;stroke-width:38;stroke-miterlimit:4;stroke:#223050;stroke-opacity:0.5;"
                d="m 66.906305,293.33748 a 160.10918,160.10918 0 0 1 10e-7,-226.428566 a 160.10918,160.10918 0 0 1 226.428574,10e-7 a 160.10918,160.10918 0 0 1 -10e-6,226.428565" />
        <path
            style="fill:none;fill-rule:evenodd;;stroke-width:40;stroke-miterlimit:4;" stroke="url(#linear)"
            id="arc"
                d="m 66.906305,293.33748 a 160.10918,160.10918 0 0 1 10e-7,-226.428566 a 160.10918,160.10918 0 0 1 226.428574,10e-7 a 160.10918,160.10918 0 0 1 -10e-6,226.428565" />

        <!-- <line class="line" x1="53" y1="306" x2="180" y2="180" style="stroke:rgb(255,0,0);stroke-width:2;transform-origin:63px 0px"
                /> -->
        <polygon id="bigLine" class="line" fill="url(#linear2)"
        points="180,168 180,192  65,188  65,172"
        style="fill-opacity:0.9;transform-origin:59px 6px" />



        <line class="metka" x1="180" y1="14" x2="180" y2="26"
                transform="rotate(226 180 180)"
                >
        </line>
        <line class="metka" x1="180" y1="14" x2="180" y2="26"
                transform="rotate(270 180 180)"
                >
        </line>
        <line class="metka" x1="180" y1="14" x2="180" y2="26"
                transform="rotate(315 180 180)"
                >
        </line>
        <line class="metka" x1="180" y1="14" x2="180" y2="26"
                transform="rotate(405 180 180)"
                >
        </line>
        <line class="metka" x1="180" y1="14" x2="180" y2="26"
                transform="rotate(450 180 180)"
                >
        </line>
        <line class="metka" x1="180" y1="14" x2="180" y2="26"
                transform="rotate(494 180 180)"
                >
        </line>
        <line class="metka" x1="180" y1="14" x2="180" y2="26">
        </line>

        <text x="85" y="275" class="number">0</text>
        <text x="50" y="187" class="number">1000</text>
        <text x="82" y="100" class="number">2000</text>
        <text x="170" y="60" class="number">3000</text>
        <text x="245" y="100" class="number">4000</text>
        <text x="278" y="187" class="number">5000</text>
        <text x="245" y="275" class="number">6000</text>



        </svg>
        <div id="speed-number" class="speed-number">0</div>
        <div class="mbps">
            RPM
        </div>
        </div>
        </div>
    </div>
</template>

<script setup>
/*
var path = document.getElementById("path");
var pathDimensions = path.getTotalLength();

segment.draw("0%", "0%", 0.1);
segment2.draw("0%", "0%", 0.1);

var counter = { var: 0 };
var tal = document.getElementById("speed-number");
var angle = 270;

var duga = 3.14*160*angle/180;

var segm = pathDimensions/5;

TweenLite.to(".line", 0.1, {rotationZ: "-45", ease:Linear.easeNone});

$('#butanim').hover(
  function(){
  TweenLite.to(".line", 1, {rotationZ: angle - 45, ease:Linear.easeNone});
    segment.draw("0%", duga, 1);
    segment2.draw("0%", duga, 1);
    TweenMax.to(counter, 1, {
      var: 30,
      onUpdate: function () {
          tal.innerHTML = Math.ceil(counter.var);
      },
      ease:Linear.easeNone
  });
  },
   function(){
   TweenLite.to(".line", 1, {rotationZ: "-45", ease:Linear.easeNone});
     segment.draw("0%", "0%", 1);
     segment2.draw("0%", "0%", 1);
     TweenMax.to(counter, 1, {
      var: 0,
      onUpdate: function () {
          tal.innerHTML = Math.ceil(counter.var);
      },
      ease:Linear.easeNone
  });
   }

);*/

</script>

<style scoped>
.metka {
  stroke:#fff;
  stroke-width:5;
}
.number {
  fill:#fff;
  font-weight:700;
  font-size:16px;
  opacity:0.8;
  font-family: 'Open Sans', sans-serif;
}
.speedometr {
  position:relative;
  max-width:350px;
}
.speed-number {
  color:#fff;
  font-family: 'Tulpen One', cursive;
  font-size:82px;
  font-weight:400;
  text-align:center;
  position:absolute;
  top:240px;
  width:100%;
}
#butanim {
  width: 10rem;
  border: 2px solid #6EFDF3;
  -webkit-appearance: none;
     -moz-appearance: none;
          appearance: none;
  position: absolute;
  left: calc(50% - 5rem);
  bottom: -5rem;
  font-size: 1.2rem;
  font-weight: bold;
  text-align: center;
  text-transform: uppercase;
  line-height: 3rem;
  color: #6EFDF3;
  border-radius: 3rem;
  background-color: transparent;
  cursor: pointer;
  outline: none;
  -webkit-transition: background-color 250ms ease-out;
  transition: background-color 250ms ease-out;
}
.mbps {
  text-align:center;
  font-size:18px;
  color:#86879D;
  width:100%;

}
.mbps svg {
   vertical-align:top;
}
</style>