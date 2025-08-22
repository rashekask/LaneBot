# LaneBot

LaneBot is a smart driving assistant for older vehicles, providing real-time object and lane detection using AI-powered backend processing and a live iOS front end. The app uses YOLOv8 for object recognition and alerts users with sound and visual feedback to enhance road safety.

---

## Features

- **Real-time video capture and object detection**  
  <img src="assets/features/object-detection.gif" width="500" alt="Object detection demo"/>

- **Front vehicle proximity alerts**  
  <img src="assets/features/proximity-alert.png" width="500" alt="Proximity alert"/>

- **Lane boundary awareness alerts**  
  <img src="assets/features/lane-awareness.gif" width="500" alt="Lane awareness"/>

- **Red light detection and warning system**  
  <img src="assets/features/redlight-detect.png" width="500" alt="Red light detection"/>

- **Custom sound alerts for different hazard types**  
  <img src="assets/features/alerts-ui.png" width="500" alt="Custom alerts UI"/>

- **Flask backend using YOLOv8 and OpenCV**  
- **iOS Swift frontend using AVFoundation and Vision**

---

## Technologies Used

### Frontend (iOS)
- Swift 5  
- UIKit, AVFoundation  
- Xcode Interface Builder  
- Custom sound alerts via AVAudioPlayer  

### Backend (Python)
- Flask  
- YOLOv8 (Ultralytics)  
- OpenCV  
- Pillow  
- pyngrok  

---

## How to Add Images

1. Create a folder in your repo: `assets/features/`  
2. Place your screenshots or GIFs inside that folder.  
3. Reference them in Markdown using:

```md
<img src="assets/features/<your-file>.png" width="500" alt="Description"/>
