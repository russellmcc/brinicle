import React from 'react';
import AUReact from 'brinicle';
import LottieKnob from './LottieKnob.js';

export default class AUParamKnob extends React.Component {
  constructor(props) {
    super(props)
    this.startGesture = () => {
      let workingGrab = AUReact.grabParameter(this.props.param);
      return {
        setNewValue: (v) => {
          workingGrab = workingGrab.then((g) =>{
            return AUReact.moveGrabbedParameter(g, v)
              .then(() => {return g;});
          });
        },
        end: () => {
          workingGrab.then((g) => {
            return AUReact.ungrabParameter(g);
          });
          workingGrab = null;
        }
      }
    };
  }
  render() {
    return <LottieKnob
      {...this.props}
      minimumValue={AUReact.parameterInfo[this.props.param].min}
      maximumValue={AUReact.parameterInfo[this.props.param].max}
      startGesture={this.startGesture}
      />
  }
};